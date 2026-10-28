%% Fixed-point parity check of Stage 2 on the SHARED hardware chain.
%
% Independently re-reads the raw WFDB records and recomputes, in MATLAB,
% everything the hardware would do for Stage 2 in the shared design:
%   linear resample to 120 Hz -> Q3.8 -> causal 3rd-order 1 Hz high-pass
%   (the same filter Stage 1 uses in train_shared_stage1.m) -> Q5.8 ->
%   shared 6-feature engine -> per-feature fixed-point formats ->
%   folded + quantized linear SVM.
% Compares against the Python export from
% hw_shared_pipeline/stage2/build_stage2_shared.py.
%
% Based on shared_frontend_validation/validate_stage2_vt_vf_120hz_shared_frontend.m
% (WFDB reader and NaN interpolation reused unchanged). Modifies no existing file.

clear;
clc;

thisDir = fileparts(mfilename('fullpath'));
pipelineRoot = fileparts(thisDir);
databasesRoot = fullfile(fileparts(fileparts(pipelineRoot)), "databases");
vfdbFolder = fullfile(databasesRoot, "mit-bih-malignant-ventricular-ectopy-database-1.0.0");
cudbFolder = fullfile(databasesRoot, "cu-ventricular-tachyarrhythmia-database-1.0.0");

artifactFile = fullfile(pipelineRoot, "stage2", "results", "stage2_shared_holdout.mat");
if exist(artifactFile, 'file') ~= 2
    error('Validation artifact not found: %s', artifactFile);
end
artifacts = load(artifactFile);

featureNames = string(artifacts.feature_names);
featureIntegerBits = double(artifacts.feature_integer_bits);
featureFractionBits = double(artifacts.feature_fraction_bits);
vtLabel = double(artifacts.vt_label);
vfLabel = double(artifacts.vf_label);
weightIntegerBits = double(artifacts.weight_integer_bits);
biasIntegerBits = double(artifacts.bias_integer_bits);
weightFractionBits = double(artifacts.weight_fraction_bits);
highpassHz = double(artifacts.highpass_hz);
highpassOrder = double(artifacts.highpass_order);

% Fold the scaler into one weight vector + bias here, independently of Python.
combinedWeight = double(artifacts.svm_coef) ./ double(artifacts.scaler_scale);
combinedBias = double(artifacts.svm_intercept) - sum(combinedWeight .* double(artifacts.scaler_mean));
combinedWeightQ = reshape(quantize_signed_q_format(combinedWeight, weightIntegerBits, weightFractionBits), 1, []);
combinedBiasQ = quantize_signed_q_format(combinedBias, biasIntegerBits, weightFractionBits);
pythonWeightQ = reshape(double(artifacts.combined_weight_q), 1, []);

fprintf('Loaded model: %d features -> %s\n', numel(featureNames), strjoin(featureNames, ', '));
fprintf('  weights Q%d.%d: %s\n', weightIntegerBits, weightFractionBits, mat2str(combinedWeightQ, 6));
fprintf('  bias    Q%d.%d: %.10g\n', biasIntegerBits, weightFractionBits, combinedBiasQ);
fprintf('  max |MATLAB-folded weight - Python-folded weight|: %.3g\n\n', max(abs(combinedWeightQ - pythonWeightQ)));

analysisFs = 120;
blockLenSamples = 30;
thresholdFraction = 0.20;
windowSeconds = 2.0;

testRecordId = string(artifacts.test_record_id);
testStart = double(artifacts.test_start_sample);
testEnd = double(artifacts.test_end_sample);
testTrueLabel = double(artifacts.test_true_label);
testPythonFixed = double(artifacts.test_python_fixed_point_label);
testFeaturesPython = double(artifacts.test_features_python);

uniqueRecords = unique(testRecordId, 'stable');
reportFile = fullfile(pipelineRoot, "stage2", "results", "matlab_stage2_shared_comparison.csv");
fid = fopen(reportFile, 'w');
cleanupFid = onCleanup(@() fclose(fid));
fprintf(fid, 'record_id,window_index,true_label,python_fixed_label,matlab_label,max_abs_feature_diff\n');

totalWindows = 0;
totalMismatches = 0;
totalCorrect = 0;
overallMaxFeatureDiff = 0;

[b, a] = butter(highpassOrder, highpassHz / (analysisFs / 2), 'high');

for r = 1:numel(uniqueRecords)
    recordId = uniqueRecords(r);
    parts = strsplit(recordId, "/");
    if parts(1) == "vfdb"
        recordPath = fullfile(vfdbFolder, parts(2));
    else
        recordPath = fullfile(cudbFolder, parts(2));
    end

    [ecgRaw, sourceFs] = local_rdsamp_212_with_invalid_detection(recordPath, 1);
    ecgRaw = interpolate_nonfinite_like_numpy(ecgRaw);
    if abs(sourceFs - analysisFs) > 1e-6
        ecgRaw = resample_ecg_only(ecgRaw, sourceFs, analysisFs);
    end

    ecg = quantize_signed_q_format(ecgRaw, 3, 8);
    ecg = filter(b, a, ecg);
    ecg = quantize_signed_q_format(ecg, 5, 8);

    recordMask = testRecordId == recordId;
    recordStart = testStart(recordMask);
    recordEnd = testEnd(recordMask);
    recordTrue = testTrueLabel(recordMask);
    recordPython = testPythonFixed(recordMask);
    recordFeaturesPython = testFeaturesPython(recordMask, :);

    recordMismatches = 0;
    recordMaxDiff = 0;
    recordCorrect = 0;
    for w = 1:numel(recordStart)
        windowSignal = ecg(recordStart(w) + 1:recordEnd(w));
        f = shared_engine_features(windowSignal, numel(windowSignal), windowSeconds, ...
            thresholdFraction, 5, 8, blockLenSamples);
        for k = 1:numel(f)
            f(k) = quantize_signed_q_format(f(k), featureIntegerBits(k), featureFractionBits(k));
        end
        decision = sum(f .* combinedWeightQ) + combinedBiasQ;
        if decision > 0
            predicted = vfLabel;
        else
            predicted = vtLabel;
        end

        maxDiff = max(abs(f - recordFeaturesPython(w, :)));
        recordMaxDiff = max(recordMaxDiff, maxDiff);
        overallMaxFeatureDiff = max(overallMaxFeatureDiff, maxDiff);
        recordMismatches = recordMismatches + (predicted ~= recordPython(w));
        recordCorrect = recordCorrect + (predicted == recordTrue(w));
        fprintf(fid, '%s,%d,%d,%d,%d,%.10g\n', recordId, w, recordTrue(w), recordPython(w), predicted, maxDiff);
    end

    fprintf('%-12s windows=%-4d  vs-Python mismatches=%-3d  max|feature diff|=%.3g  MATLAB accuracy=%.4f\n', ...
        recordId, numel(recordStart), recordMismatches, recordMaxDiff, recordCorrect / max(numel(recordStart), 1));
    totalWindows = totalWindows + numel(recordStart);
    totalMismatches = totalMismatches + recordMismatches;
    totalCorrect = totalCorrect + recordCorrect;
end

fprintf('\nTotal windows: %d\n', totalWindows);
fprintf('MATLAB vs Python fixed-point prediction mismatches: %d (%.2f%%)\n', totalMismatches, ...
    100 * totalMismatches / max(totalWindows, 1));
fprintf('Overall max |feature diff| (any feature, any window): %.3g\n', overallMaxFeatureDiff);
fprintf('MATLAB fixed-point accuracy vs true labels: %.4f\n', totalCorrect / max(totalWindows, 1));
fprintf('Wrote %s\n', reportFile);

%% ---- functions ----

function f = shared_engine_features(v, windowLength, windowSeconds, thresholdFraction, integerBits, fractionBits, blockLength)
% Identical to shared_engine_features in train_shared_stage1.m.
v = v(:);
windowMean = quantize_signed_q_format(sum(v, 'omitnan') / windowLength, integerBits, fractionBits);
c = v - windowMean;
d = diff(c);
a = abs(c);
meanAbs = quantize_signed_q_format(sum(a, 'omitnan') / windowLength, integerBits, fractionBits);
zeroCrossings = count_zero_crossings(d) / windowSeconds;
lineLength = sum(abs(d), 'omitnan') / windowSeconds;
thresholdCrossingCount = count_threshold_crossings(c, thresholdFraction);
numBlocks = floor(windowLength / blockLength);
blockMeans = mean(reshape(a(1:numBlocks * blockLength), blockLength, numBlocks), 1);
localAmpRange = max(blockMeans) - min(blockMeans);
ampTransition = mean(abs(diff(blockMeans)));
f = [meanAbs, zeroCrossings, lineLength, thresholdCrossingCount, localAmpRange, ampTransition];
end

function zc = count_zero_crossings(x)
x = x(:);
x = x(isfinite(x));
if length(x) < 2
    zc = 0;
    return;
end
signs = sign(x);
for k = 2:length(signs)
    if signs(k) == 0
        signs(k) = signs(k - 1);
    end
end
if signs(1) == 0
    firstNonZero = find(signs ~= 0, 1, 'first');
    if isempty(firstNonZero)
        zc = 0;
        return;
    end
    signs(1:firstNonZero - 1) = signs(firstNonZero);
end
zc = sum(signs(1:end-1) .* signs(2:end) < 0);
end

function tc = count_threshold_crossings(x, thresholdFraction)
x = x(:);
x = x(isfinite(x));
if length(x) < 2
    tc = 0;
    return;
end
threshold = thresholdFraction * max(abs(x));
if ~isfinite(threshold) || threshold <= 0
    tc = 0;
    return;
end
aboveThreshold = abs(x) >= threshold;
tc = sum(aboveThreshold(1:end-1) ~= aboveThreshold(2:end));
end

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
interpolated(missingIdx < finiteIdx(1)) = finiteVal(1);
interpolated(missingIdx > finiteIdx(end)) = finiteVal(end);
result(~finite) = interpolated;
end

function [signal, Fs] = local_rdsamp_212_with_invalid_detection(recordname, channel)
heaFile = [char(recordname), '.hea'];
fid = fopen(heaFile, 'r');
if fid < 0
    error('Could not open header file: %s', heaFile);
end
cleanup = onCleanup(@() fclose(fid));
headerParts = strsplit(strtrim(fgetl(fid)));
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
elseif channel == 1
    adc = firstSample;
else
    adc = secondSample;
end
adc = adc(1:min(numSamples, length(adc)));
adc(adc == -2048) = NaN;
if isfinite(gain) && gain ~= 0
    signal = (adc - baseline) ./ gain;
else
    signal = adc - baseline;
end
end
