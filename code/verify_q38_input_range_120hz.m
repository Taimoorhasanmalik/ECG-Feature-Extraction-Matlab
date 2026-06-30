%% Verify signed Q3.8 input range coverage at 120 Hz
% Checks the ECG values at the same point used by the Q3.8 trainers:
% after first-channel WFDB format-212 conversion and 120 Hz resampling,
% before feature extraction.

clear;
clc;

scriptDir = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
databaseFolders = [
    fullfile(projectRoot, "databases", "mit-bih-arrhythmia-database-1.0.0"), ...
    fullfile(projectRoot, "databases", "mit-bih-malignant-ventricular-ectopy-database-1.0.0"), ...
    fullfile(projectRoot, "databases", "cu-ventricular-tachyarrhythmia-database-1.0.0")];
databaseNames = ["mitdb", "vfdb", "cudb"];

targetSampleRateHz = 120;
integerBits = 3;
fractionBits = 8;
scale = 2 ^ fractionBits;
qMin = -2 ^ integerBits;
qMax = 2 ^ integerBits - 1 / scale;

fprintf('\nSigned Q3.8 input range verification at %.2f Hz\n', targetSampleRateHz);
fprintf('Q3.8 range [%.9f, %.9f], step %.9f, quantizer fix(x * %d) / %d\n', ...
    qMin, qMax, 1 / scale, scale, scale);

overall = init_stats("overall");
for dbIdx = 1:numel(databaseFolders)
    folder = databaseFolders(dbIdx);
    dbName = databaseNames(dbIdx);
    if exist(folder, 'dir') ~= 7
        warning('Database folder not found: %s', folder);
        continue;
    end

    stats = init_stats(dbName);
    records = dir(fullfile(folder, '*.hea'));
    fprintf('\nReading %s: %d records\n', dbName, numel(records));

    for recordIdx = 1:numel(records)
        recordName = fullfile(records(recordIdx).folder, erase(records(recordIdx).name, ".hea"));
        [ecg, Fs] = local_rdsamp_212(recordName, 1);
        ecg = double(ecg(:));

        if abs(Fs - targetSampleRateHz) > eps
            sourceTime = (0:length(ecg)-1).' / Fs;
            targetTime = (0:1/targetSampleRateHz:sourceTime(end)).';
            ecg = interp1(sourceTime, ecg, targetTime, 'linear', 'extrap');
        end

        stats = update_stats(stats, ecg, qMin, qMax, scale);
        overall = update_stats(overall, ecg, qMin, qMax, scale);
    end

    print_stats(stats);
end

fprintf('\nCombined database coverage:\n');
print_stats(overall);

function stats = init_stats(name)
stats.name = string(name);
stats.records = 0;
stats.samples = 0;
stats.minValue = inf;
stats.maxValue = -inf;
stats.maxAbs = 0;
stats.below = 0;
stats.above = 0;
stats.atMin = 0;
stats.atMax = 0;
stats.absErrorSum = 0;
stats.absErrorMax = 0;
stats.sqErrorSum = 0;
end

function stats = update_stats(stats, x, qMin, qMax, scale)
x = double(x(:));
if isempty(x)
    return;
end

q = fix(x * scale) / scale;
q = min(max(q, qMin), qMax);
err = abs(q - x);

stats.records = stats.records + 1;
stats.samples = stats.samples + numel(x);
stats.minValue = min(stats.minValue, min(x));
stats.maxValue = max(stats.maxValue, max(x));
stats.maxAbs = max(stats.maxAbs, max(abs(x)));
stats.below = stats.below + sum(x < qMin);
stats.above = stats.above + sum(x > qMax);
stats.atMin = stats.atMin + sum(q == qMin);
stats.atMax = stats.atMax + sum(q == qMax);
stats.absErrorSum = stats.absErrorSum + sum(err);
stats.absErrorMax = max(stats.absErrorMax, max(err));
stats.sqErrorSum = stats.sqErrorSum + sum(err .^ 2);
end

function print_stats(stats)
if stats.samples == 0
    fprintf('%s: no samples\n', stats.name);
    return;
end

clipCount = stats.below + stats.above;
fprintf('%s\n', stats.name);
fprintf('  Records: %d | Samples after resampling: %d\n', stats.records, stats.samples);
fprintf('  Value range: [%.6f, %.6f] | max abs %.6f\n', ...
    stats.minValue, stats.maxValue, stats.maxAbs);
fprintf('  Outside Q3.8 range: %d samples (%.8f%%) | below %d | above %d\n', ...
    clipCount, 100 * clipCount / stats.samples, stats.below, stats.above);
fprintf('  Saturated quantized samples: min %d (%.8f%%), max %d (%.8f%%)\n', ...
    stats.atMin, 100 * stats.atMin / stats.samples, ...
    stats.atMax, 100 * stats.atMax / stats.samples);
fprintf('  Quantization abs error: mean %.9f | max %.9f | RMSE %.9f\n', ...
    stats.absErrorSum / stats.samples, stats.absErrorMax, ...
    sqrt(stats.sqErrorSum / stats.samples));
end

function [signal, Fs] = local_rdsamp_212(recordname, channel)
heaFile = [char(recordname), '.hea'];
fid = fopen(heaFile, 'r');
if fid < 0
    error('Could not open header file: %s', heaFile);
end

cleanup = onCleanup(@() fclose(fid));
headerLine = strtrim(fgetl(fid));
headerParts = strsplit(headerLine);
numSignals = str2double(headerParts{2});
Fs = str2double(headerParts{3});
numSamples = str2double(headerParts{4});

signalInfo = cell(numSignals, 1);
for k = 1:numSignals
    signalInfo{k} = strsplit(strtrim(fgetl(fid)));
end

if channel > numSignals
    error('Requested channel %d, but record only has %d channel(s).', channel, numSignals);
end

datFile = fullfile(fileparts(heaFile), signalInfo{channel}{1});
formatCode = str2double(signalInfo{channel}{2});
gain = str2double(signalInfo{channel}{3});
baseline = str2double(signalInfo{channel}{5});

if formatCode ~= 212
    error('Fallback reader only supports WFDB format 212. Found format %d in %s.', formatCode, heaFile);
end

fidDat = fopen(datFile, 'r');
if fidDat < 0
    error('Could not open data file: %s', datFile);
end
datCleanup = onCleanup(@() fclose(fidDat));

bytes = fread(fidDat, inf, 'uint8=>double');
usableBytes = floor(length(bytes) / 3) * 3;
bytes = reshape(bytes(1:usableBytes), 3, [])';

firstSample = bytes(:, 1) + 256 * bitand(bytes(:, 2), 15);
secondSample = bytes(:, 3) + 256 * bitshift(bytes(:, 2), -4);

firstSample(firstSample >= 2048) = firstSample(firstSample >= 2048) - 4096;
secondSample(secondSample >= 2048) = secondSample(secondSample >= 2048) - 4096;

if numSignals == 1
    adc = reshape([firstSample.'; secondSample.'], [], 1);
else
    if channel == 1
        adc = firstSample;
    else
        adc = secondSample;
    end
end

adc = adc(1:min(numSamples, length(adc)));
if isfinite(gain) && gain ~= 0
    signal = (double(adc(:)) - baseline) / gain;
else
    signal = double(adc(:));
end
end
