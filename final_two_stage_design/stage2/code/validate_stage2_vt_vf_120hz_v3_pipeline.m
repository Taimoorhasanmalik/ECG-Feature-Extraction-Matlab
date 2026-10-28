%% Fixed-point hardware-producibility validation of the 120 Hz Stage 2 model.
%
% Same structure as validate_stage2_vt_vf_fixed_point_pipeline.m (Q3.8
% signal, Q2.13 folded classifier weights, WFDB invalid-sample detection,
% causal 4-biquad 0.5-40 Hz filter, the 7 hardware-light features), but at
% 240 Hz instead of 250 Hz -- chosen as 2x Stage 1's 120 Hz so hardware can
% derive both rates from one clock via an integer divider. VFDB/CUDB are
% natively 250 Hz, so this ADDS a resampling step (250 -> 240, done via
% linear interpolation, matching the same approach already used for Stage
% 1's 250 -> 120 Hz resampling) that the 250 Hz validation script never
% needed. At 240 Hz, block length is exactly 60 samples (0.25s * 240, no
% rounding) and 8 blocks cover the full 480-sample window with no leftover
% samples, unlike 250 Hz's 496-of-500 truncation.
%
% This does not modify or retrain anything. Modifies no existing file.

clear;
clc;

projectRoot = fileparts(fileparts(fileparts(mfilename('fullpath'))));
databasesRoot = fullfile(fileparts(projectRoot), "databases");
vfdbFolder = fullfile(databasesRoot, "mit-bih-malignant-ventricular-ectopy-database-1.0.0");
cudbFolder = fullfile(databasesRoot, "cu-ventricular-tachyarrhythmia-database-1.0.0");

artifactFile = fullfile(projectRoot, "greedy_record_inclusion", "results", "stage2_matlab_validation_artifacts_120hz_v3.mat");
if exist(artifactFile, 'file') ~= 2
    error('Validation artifact not found: %s', artifactFile);
end
artifacts = load(artifactFile);

featureNames = string(artifacts.feature_names);
scalerMean = artifacts.scaler_mean;
scalerScale = artifacts.scaler_scale;
svmCoef = artifacts.svm_coef;
svmIntercept = artifacts.svm_intercept;
vtLabel = artifacts.vt_label;
vfLabel = artifacts.vf_label;

combinedWeight = svmCoef ./ scalerScale;
combinedBias = svmIntercept - sum(combinedWeight .* scalerMean);

signalIntegerBits = 3;          % Q3.8 pre-filter (matches Stage 1's own signal format)
signalFractionBits = 8;
postFilterIntegerBits = 5;   % Q5.8 -- uniform wide format used at both the DC-blocker output and the main filter output
                                 % its input range (worst case 13.7 across the 49-record pool);
                                 % Q3.8 silently clipped inside a real held-out test window
                                 % before this fix. Same fraction width, wider integer headroom.
weightIntegerBits = 2;
weightFractionBits = 13;

combinedWeightQ = reshape(quantize_signed_q_format(combinedWeight, weightIntegerBits, weightFractionBits), 1, []);
combinedBiasQ = quantize_signed_q_format(combinedBias, weightIntegerBits, weightFractionBits);

fprintf('Loaded model: %d features -> %s\n', numel(featureNames), strjoin(featureNames, ', '));
fprintf('  combinedWeight (Q%d.%d): %s\n', weightIntegerBits, weightFractionBits, mat2str(combinedWeightQ, 6));
fprintf('  combinedBias   (Q%d.%d): %.10g\n\n', weightIntegerBits, weightFractionBits, combinedBiasQ);

analysisFs = 120;
blockLenSamples = 30;   % 0.25 * 120 = 30 exactly
thresholdFraction = 0.20;
deadbandFraction = 0.05;

testRecordId = string(artifacts.test_record_id);
testStart = double(artifacts.test_start_sample);
testEnd = double(artifacts.test_end_sample);
testTrueLabel = double(artifacts.test_true_label);
testPythonPredicted = double(artifacts.test_python_predicted_label);
testFeaturesPython = double(artifacts.test_features_python);

uniqueRecords = unique(testRecordId, 'stable');

outputFolder = fullfile(projectRoot, "greedy_record_inclusion", "results", "stage2_120hz_v3_validation_2026_09_30");
if exist(outputFolder, 'dir') ~= 7
    mkdir(outputFolder);
end
reportFile = fullfile(outputFolder, "matlab_120hz_v3_comparison.csv");
fid = fopen(reportFile, 'w');
cleanupFid = onCleanup(@() fclose(fid));
fprintf(fid, 'record_id,window_index,true_label,python_predicted_label,matlab_predicted_label,max_abs_feature_diff\n');

totalWindows = 0;
totalVsPythonMismatches = 0;
totalCorrect = 0;
overallMaxFeatureDiff = 0;

for r = 1:numel(uniqueRecords)
    recordId = uniqueRecords(r);
    parts = strsplit(recordId, "/");
    db = parts(1);
    name = parts(2);
    if db == "vfdb"
        recordPath = fullfile(vfdbFolder, name);
    else
        recordPath = fullfile(cudbFolder, name);
    end

    [ecgRaw, sourceFs] = local_rdsamp_212_with_invalid_detection(recordPath, 1);
    ecgRaw = interpolate_nonfinite_like_numpy(ecgRaw);
    if abs(sourceFs - analysisFs) > 1e-6
        ecgRaw = resample_ecg_only(ecgRaw, sourceFs, analysisFs);
    end

    ecg = apply_causal_dc_blocker(ecgRaw, analysisFs, 0.1);
    ecg = quantize_signed_q_format(ecg, postFilterIntegerBits, signalFractionBits);
    ecg = apply_causal_bandpass_05_40(ecg, analysisFs);
    ecg = quantize_signed_q_format(ecg, postFilterIntegerBits, signalFractionBits);

    recordMask = testRecordId == recordId;
    recordStart = testStart(recordMask);
    recordEnd = testEnd(recordMask);
    recordTrueLabel = testTrueLabel(recordMask);
    recordPythonPredicted = testPythonPredicted(recordMask);
    recordFeaturesPython = testFeaturesPython(recordMask, :);

    numWindows = numel(recordStart);
    recordMismatches = 0;
    recordMaxDiff = 0;
    recordCorrect = 0;

    for w = 1:numWindows
        startIdx = recordStart(w) + 1;
        endIdx = recordEnd(w);
        windowSignal = ecg(startIdx:endIdx);

        featuresMatlab = compute_seven_features(windowSignal, blockLenSamples, thresholdFraction, deadbandFraction);
        decision = sum(featuresMatlab .* combinedWeightQ) + combinedBiasQ;
        if decision > 0
            predictedMatlab = vfLabel;
        else
            predictedMatlab = vtLabel;
        end

        maxDiff = max(abs(featuresMatlab - recordFeaturesPython(w, :)));
        recordMaxDiff = max(recordMaxDiff, maxDiff);
        overallMaxFeatureDiff = max(overallMaxFeatureDiff, maxDiff);

        if predictedMatlab ~= recordPythonPredicted(w)
            recordMismatches = recordMismatches + 1;
        end
        if predictedMatlab == recordTrueLabel(w)
            recordCorrect = recordCorrect + 1;
        end

        fprintf(fid, '%s,%d,%d,%d,%d,%.10g\n', recordId, w, recordTrueLabel(w), ...
            recordPythonPredicted(w), predictedMatlab, maxDiff);
    end

    fprintf('%-12s windows=%-4d  vs-Python prediction mismatches=%-3d  max|feature diff|=%.3g  MATLAB accuracy=%.4f\n', ...
        recordId, numWindows, recordMismatches, recordMaxDiff, recordCorrect / max(numWindows, 1));

    totalWindows = totalWindows + numWindows;
    totalVsPythonMismatches = totalVsPythonMismatches + recordMismatches;
    totalCorrect = totalCorrect + recordCorrect;
end

fprintf('\nTotal windows: %d\n', totalWindows);
fprintf('MATLAB vs Python prediction mismatches: %d (%.2f%%)\n', totalVsPythonMismatches, ...
    100 * totalVsPythonMismatches / max(totalWindows, 1));
fprintf('Overall max |feature diff| (MATLAB vs Python, any feature, any window): %.3g\n', overallMaxFeatureDiff);
fprintf('MATLAB fixed-point standalone accuracy vs true labels: %.4f  (Python float reference: 0.9510)\n', ...
    totalCorrect / max(totalWindows, 1));
fprintf('Wrote %s\n', reportFile);

%% ---- functions ----

function targetEcg = resample_ecg_only(ecg, sourceFs, targetFs)
ecg = double(ecg(:));
numSamples = length(ecg);
if numSamples == 0
    targetEcg = ecg;
    return;
end
sourceTime = (0:numSamples - 1)' ./ sourceFs;
targetNumSamples = max(1, floor(sourceTime(end) * targetFs) + 1);
targetTime = (0:targetNumSamples - 1)' ./ targetFs;
targetEcg = interp1(sourceTime, ecg, targetTime, 'linear', 'extrap');
end

function quantizedValue = quantize_signed_q_format(value, integerBits, fractionBits)
value = double(value);
scale = 2 ^ fractionBits;
qMin = -2 ^ integerBits;
qMax = 2 ^ integerBits - 1 / scale;
quantizedValue = fix(value * scale) / scale;
quantizedValue = min(max(quantizedValue, qMin), qMax);
end

function result = interpolate_nonfinite_like_numpy(signal)
signal = double(signal(:));
finite = isfinite(signal);
if all(finite)
    result = signal;
    return;
end
if ~any(finite)
    error('Signal contains no finite samples');
end
indices = (1:numel(signal))';
finiteIdx = indices(finite);
finiteVal = signal(finite);
result = signal;
missingIdx = indices(~finite);
interpolated = interp1(finiteIdx, finiteVal, missingIdx, 'linear');
belowRange = missingIdx < finiteIdx(1);
aboveRange = missingIdx > finiteIdx(end);
interpolated(belowRange) = finiteVal(1);
interpolated(aboveRange) = finiteVal(end);
result(~finite) = interpolated;
end

function featureRow = compute_seven_features(windowSignal, blockLenSamples, thresholdFraction, deadbandFraction)
windowSignal = double(windowSignal(:));
centered = windowSignal - mean(windowSignal);
derivativeSignal = diff(centered);

meanAbsAmp = mean(abs(centered));
lineLength = sum(abs(derivativeSignal));

deadband = deadbandFraction * mean(abs(derivativeSignal));
retained = derivativeSignal(abs(derivativeSignal) > deadband);
if numel(retained) < 2
    derivativeZeroCrossings = 0;
else
    isNegative = retained < 0;
    derivativeZeroCrossings = sum(isNegative(1:end-1) ~= isNegative(2:end));
end

threshold = thresholdFraction * max(abs(centered));
if threshold > 0
    above = abs(centered) >= threshold;
else
    above = false(size(centered));
end
thresholdCrossings = sum(above(1:end-1) ~= above(2:end));

numBlocks = floor(numel(centered) / blockLenSamples);
blockMeans = zeros(numBlocks, 1);
for k = 1:numBlocks
    blockStart = (k - 1) * blockLenSamples + 1;
    blockEnd = k * blockLenSamples;
    blockMeans(k) = mean(abs(centered(blockStart:blockEnd)));
end
localAmpMean = mean(blockMeans);
localAmpRange = max(blockMeans) - min(blockMeans);
if numBlocks >= 2
    ampTransition = mean(abs(diff(blockMeans)));
else
    ampTransition = 0;
end

% Per-feature fixed-point quantization -- sized from each feature's own
% observed range (see vt_vf_export_quantized_feature_matlab_artifacts.py):
% amplitude-scale features reuse the signal's own Q3.8; line_length gets a
% wider integer accumulator (Q8.8); the two counts need no fraction at all (Q8.0).
meanAbsAmp = quantize_signed_q_format(meanAbsAmp, 3, 8);
lineLength = quantize_signed_q_format(lineLength, 8, 8);
derivativeZeroCrossings = quantize_signed_q_format(derivativeZeroCrossings, 8, 0);
thresholdCrossings = quantize_signed_q_format(thresholdCrossings, 8, 0);
localAmpMean = quantize_signed_q_format(localAmpMean, 3, 8);
localAmpRange = quantize_signed_q_format(localAmpRange, 3, 8);
ampTransition = quantize_signed_q_format(ampTransition, 3, 8);

featureRow = [meanAbsAmp, lineLength, derivativeZeroCrossings, thresholdCrossings, ...
    localAmpMean, localAmpRange, ampTransition];
end

function filteredEcg = apply_causal_bandpass_05_40(ecg, fs)
ecg = double(ecg(:));
nyquistHz = fs / 2;
[z, p, k] = butter(4, [0.5, 40.0] / nyquistHz, 'bandpass');
[sos, g] = zp2sos(z, p, k);
sos(1, 1:3) = sos(1, 1:3) * g;
filteredEcg = ecg;
for section = 1:size(sos, 1)
    filteredEcg = filter(sos(section, 1:3), sos(section, 4:6), filteredEcg);
end
end

function filteredEcg = apply_causal_dc_blocker(ecg, fs, cutoffHz)
% Single-pole causal highpass (1st-order Butterworth) replacing the
% non-causal whole-record median subtraction. Cutoff sits a full octave+
% below the main bandpass filter's own 0.5 Hz low corner, so it removes DC/
% slow baseline drift without touching the 0.5-40 Hz band Stage 2 needs intact.
ecg = double(ecg(:));
nyquistHz = fs / 2;
[b, a] = butter(1, cutoffHz / nyquistHz, 'high');
filteredEcg = filter(b, a, ecg);
end

function [signal, Fs] = local_rdsamp_212_with_invalid_detection(recordname, channel)
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
    error('Fallback reader only supports WFDB format 212. Found format %d.', formatCode);
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

invalidSentinel = -2048;
adc(adc == invalidSentinel) = NaN;

if isfinite(gain) && gain ~= 0
    signal = (adc - baseline) ./ gain;
else
    signal = adc - baseline;
end
end
