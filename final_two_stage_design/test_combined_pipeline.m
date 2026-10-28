%% End-to-end test of the combined two-stage pipeline in this folder.
%
% Stage 1 = ./stage1 (final_low_power_design, UNCHANGED: Q3.8 throughout,
%   causal 5 Hz Pan-Tompkins-style highpass, 4 features, 2-of-3 sequence
%   vote gate). Stage 2 = ./stage2 (latest 120 Hz hardware deliverable:
%   causal DC-blocker + 0.5-40 Hz bandpass, uniform Q5.8, 7 features,
%   Q2.13 linear classifier). Both run at 120 Hz on the same window/stride
%   grid (2.0s window, 1.0s step) so their window boundaries align sample-
%   for-sample, which is what makes gating Stage 2 by Stage 1 meaningful.
%
% For each of Stage 2's 4 genuinely held-out records (vfdb/615, vfdb/429,
% cudb/cu13, cudb/cu32 -- never trained on by either stage's own held-out
% split), this script:
%   1. Runs Stage 1 continuously over the whole record (its own Q3.8
%      preprocessing + 4 features + base SVM score + 2-of-3 sequence vote)
%      to get a gate_active bit per window.
%   2. Runs Stage 2 continuously over the whole record (its own Q5.8
%      preprocessing + 7 features + Q2.13 classifier) to get a VT/VF
%      prediction per window.
%   3. At exactly the windows Stage 2's own validation artifact has ground
%      truth for (real VT or VF-family), looks up Stage 1's gate decision
%      at that same window and reports the full combined confusion:
%      caught-and-correctly-classified, caught-but-misclassified-VT/VF,
%      and missed-by-Stage-1 (Stage 1 never woke Stage 2 at all).
%
% This does not modify or retrain anything, and does not touch any file
% under final_low_power_design/ or stage2_hardware_deliverable/ -- it only
% reads the copies made into this folder.

clear;
clc;

thisDir = fileparts(mfilename('fullpath'));
projectRoot = fileparts(thisDir);
databasesRoot = fullfile(fileparts(projectRoot), "databases");
vfdbFolder = fullfile(databasesRoot, "mit-bih-malignant-ventricular-ectopy-database-1.0.0");
cudbFolder = fullfile(databasesRoot, "cu-ventricular-tachyarrhythmia-database-1.0.0");

analysisFs = 120;
windowSeconds = 2.0;
stepSeconds = 1.0;

%% ---- Stage 1: load base model (unchanged final_low_power_design) ----

stage1ModelFile = fullfile(thisDir, "stage1", "models", ...
    "stage1_normal_vs_abnormal_window_quantized_q3_8_fix_meanonly_pthighpass_recall90_guard98_robust_lsvm_120hz_without_rms_amplitude_robust_range.mat");
stage1Data = load(stage1ModelFile);
stage1Model = stage1Data.normal_abnormal_svm_model;
stage1Threshold = stage1Data.decisionThreshold;
stage1QInt = 3;
stage1QFrac = 8;
stage1HighpassHz = 5;
stage1HighpassOrder = 3;
stage1ThresholdFraction = 0.20;
sequenceLength = 3;
sequenceVoteThreshold = 2;   % the selected 2-of-3 rule

fprintf('Stage 1 model: %s\n', stage1ModelFile);
fprintf('Stage 1 base decision threshold: %.10g | sequence rule: %d-of-%d\n\n', ...
    stage1Threshold, sequenceVoteThreshold, sequenceLength);

%% ---- Stage 2: load and fold the Q2.13 classifier (latest 120 Hz deliverable) ----

stage2ArtifactFile = fullfile(thisDir, "stage2", "models", "stage2_matlab_validation_artifacts_120hz_v3.mat");
stage2Artifacts = load(stage2ArtifactFile);
vtLabel = stage2Artifacts.vt_label;
vfLabel = stage2Artifacts.vf_label;
combinedWeight = stage2Artifacts.svm_coef ./ stage2Artifacts.scaler_scale;
combinedBias = stage2Artifacts.svm_intercept - sum(combinedWeight .* stage2Artifacts.scaler_mean);
weightIntegerBits = 2;
weightFractionBits = 13;
combinedWeightQ = reshape(quantize_signed_q_format(combinedWeight, weightIntegerBits, weightFractionBits), 1, []);
combinedBiasQ = quantize_signed_q_format(combinedBias, weightIntegerBits, weightFractionBits);

stage2PostFilterQInt = 5;
stage2QFrac = 8;
blockLenSamples = 30;
stage2ThresholdFraction = 0.20;
deadbandFraction = 0.05;

% Ground truth across ALL of Stage 2's records (34 train + 4 held-out
% test), not just the 4-record test-only fields in the artifact -- exported
% from the same Python v3 cache used to build/validate Stage 2
% (causal_filter_120hz_v3_cache.npz), so train-record windows get the exact
% same VT/VF-interval ground truth the test-record windows already had.
groundTruthFile = fullfile(thisDir, "stage2", "models", "all_records_vtvf_ground_truth_120hz.csv");
groundTruthTable = readtable(groundTruthFile, 'TextType', 'string');
allRecordId = groundTruthTable.record_id;
allStart = double(groundTruthTable.start_sample);
allEnd = double(groundTruthTable.end_sample);
allTrueLabel = double(groundTruthTable.true_label);
allSplit = groundTruthTable.split;
uniqueRecords = unique(allRecordId, 'stable');

fprintf('Stage 2 artifact: %s\n', stage2ArtifactFile);
fprintf('Ground truth: %s\n', groundTruthFile);
fprintf('Records: %d total (%d train, %d test)\n\n', numel(uniqueRecords), ...
    numel(unique(allRecordId(allSplit == "train"))), numel(unique(allRecordId(allSplit == "test"))));

%% ---- Combined per-record evaluation ----

splitNames = ["train", "test"];
stats = struct();
stage2OnlyStats = struct();
for s = splitNames
    stats.(s) = struct('totalVT', 0, 'totalVF', 0, 'caughtVT', 0, 'caughtVF', 0, ...
        'correctVT', 0, 'correctVF', 0, 'missedVT', 0, 'missedVF', 0);
    stage2OnlyStats.(s) = struct('totalVT', 0, 'totalVF', 0, 'correctVT', 0, 'correctVF', 0);
end

for r = 1:numel(uniqueRecords)
    recordId = uniqueRecords(r);
    parts = strsplit(recordId, "/");
    if parts(1) == "vfdb"
        recordPath = fullfile(vfdbFolder, parts(2));
    else
        recordPath = fullfile(cudbFolder, parts(2));
    end

    [ecgRaw, sourceFs] = local_rdsamp_212(recordPath, 1);
    ecgRaw = interpolate_nonfinite(ecgRaw);
    if abs(sourceFs - analysisFs) > 1e-6
        ecgRaw = resample_ecg_only(ecgRaw, sourceFs, analysisFs);
    end

    % --- Stage 1 stream: its own preprocessing, features, base score, sequence gate ---
    ecg1 = quantize_signed_q_format(ecgRaw, stage1QInt, stage1QFrac);
    ecg1 = apply_causal_pantompkins_highpass(ecg1, analysisFs, stage1HighpassHz, stage1HighpassOrder);
    ecg1 = quantize_signed_q_format(ecg1, stage1QInt, stage1QFrac);

    windowLength = round(windowSeconds * analysisFs);
    stepLength = round(stepSeconds * analysisFs);
    numWindows1 = floor((length(ecg1) - windowLength) / stepLength) + 1;

    X1 = zeros(numWindows1, 4);
    windowStartSample1 = zeros(numWindows1, 1);
    for w = 1:numWindows1
        startIdx = (w - 1) * stepLength + 1;
        endIdx = startIdx + windowLength - 1;
        windowStartSample1(w) = startIdx - 1;   % 0-based, matches Stage 2 artifact convention
        windowSignal = ecg1(startIdx:endIdx);
        windowMean = quantize_signed_q_format(sum(windowSignal, 'omitnan') / windowLength, stage1QInt, stage1QFrac);
        windowSignal = windowSignal - windowMean;
        diffSignal = diff(windowSignal);
        meanAbs = quantize_signed_q_format(sum(abs(windowSignal), 'omitnan') / windowLength, stage1QInt, stage1QFrac);
        zeroCrossings = count_zero_crossings(diffSignal) / windowSeconds;
        lineLength = sum(abs(diffSignal), 'omitnan') / windowSeconds;
        thresholdCrossingCount = count_threshold_crossings(windowSignal, stage1ThresholdFraction);
        X1(w, :) = [meanAbs, zeroCrossings, lineLength, thresholdCrossingCount];
    end
    [~, scores1] = predict(stage1Model, X1);
    baseAbnormal = scores1(:, 2) >= stage1Threshold;

    voteCount = zeros(numWindows1, 1);
    for w = 1:numWindows1
        lo = max(1, w - sequenceLength + 1);
        voteCount(w) = sum(baseAbnormal(lo:w));
    end
    gateActive = voteCount >= sequenceVoteThreshold;

    % Stage 2 cold-start warm-up: it is power-gated off while Stage 1's gate
    % is inactive, with zero prior filter state and an empty window buffer.
    % When the gate first activates, Stage 2 cannot classify that same
    % window -- it needs w+3 (one window of Stage 1 decision latency, plus
    % two more window-steps to fill its own fresh 240-sample window buffer)
    % before its first valid classification. So Stage 2 only actually
    % produces output once the gate has been continuously active for >= 4
    % consecutive windows (the activating window itself, plus 3 more); a
    % gate drop-out and re-activation resets the warm-up from zero again.
    activeStreak = zeros(numWindows1, 1);
    for w = 1:numWindows1
        if gateActive(w)
            if w == 1
                activeStreak(w) = 1;
            else
                activeStreak(w) = activeStreak(w - 1) + 1;
            end
        else
            activeStreak(w) = 0;
        end
    end
    stage2Ready = activeStreak >= 4;
    gateActive = gateActive & stage2Ready;

    % --- Stage 2 stream: its own preprocessing + 7 features (predicted only where needed) ---
    ecg2 = apply_causal_dc_blocker(ecgRaw, analysisFs, 0.1);
    ecg2 = quantize_signed_q_format(ecg2, stage2PostFilterQInt, stage2QFrac);
    ecg2 = apply_causal_bandpass_05_40(ecg2, analysisFs);
    ecg2 = quantize_signed_q_format(ecg2, stage2PostFilterQInt, stage2QFrac);

    % --- Combine at Stage 2's known-ground-truth windows for this record ---
    mask = allRecordId == recordId;
    starts = allStart(mask);
    ends = allEnd(mask);
    trueLabels = allTrueLabel(mask);
    recordSplit = allSplit(find(mask, 1));
    s = stats.(recordSplit);
    s2 = stage2OnlyStats.(recordSplit);

    for k = 1:numel(starts)
        % Stage 2's test windows are anchored to each VT/VF interval's own
        % start sample (from the Python dataset-extraction script), not to
        % the record's absolute t=0 grid Stage 1 windows continuously from
        % -- so they will not generally land exactly on a Stage 1 window
        % boundary. In real continuous streaming, both stages tick from the
        % same t=0 grid, so the nearest Stage 1 window is the one that would
        % actually be active at this point in time.
        [~, stage1Idx] = min(abs(windowStartSample1 - starts(k)));
        isGateActive = gateActive(stage1Idx);

        if trueLabels(k) == vtLabel
            s.totalVT = s.totalVT + 1;
        else
            s.totalVF = s.totalVF + 1;
        end

        % Stage 2 standalone (ungated): always classify this ground-truth
        % window, regardless of whether Stage 1's gate would have fired --
        % this is Stage 2's own accuracy on its full train/test pool, the
        % same question its own isolated validation asks.
        windowSignal2 = ecg2(starts(k) + 1 : ends(k));
        features2 = compute_seven_features(windowSignal2, blockLenSamples, stage2ThresholdFraction, deadbandFraction);
        decision = sum(features2 .* combinedWeightQ) + combinedBiasQ;
        if decision > 0
            predicted = vfLabel;
        else
            predicted = vtLabel;
        end
        if trueLabels(k) == vtLabel
            s2.totalVT = s2.totalVT + 1;
            s2.correctVT = s2.correctVT + double(predicted == vtLabel);
        else
            s2.totalVF = s2.totalVF + 1;
            s2.correctVF = s2.correctVF + double(predicted == vfLabel);
        end

        if ~isGateActive
            if trueLabels(k) == vtLabel
                s.missedVT = s.missedVT + 1;
            else
                s.missedVF = s.missedVF + 1;
            end
            continue;
        end

        if trueLabels(k) == vtLabel
            s.caughtVT = s.caughtVT + 1;
            s.correctVT = s.correctVT + double(predicted == vtLabel);
        else
            s.caughtVF = s.caughtVF + 1;
            s.correctVF = s.correctVF + double(predicted == vfLabel);
        end
    end
    stats.(recordSplit) = s;
    stage2OnlyStats.(recordSplit) = s2;

    fprintf('%-12s [%-5s] processed (%d Stage-1 windows, %d ground-truth windows)\n', ...
        recordId, recordSplit, numWindows1, numel(starts));
end

%% ---- Report ----

combinedStats = struct( ...
    'totalVT', stats.train.totalVT + stats.test.totalVT, ...
    'totalVF', stats.train.totalVF + stats.test.totalVF, ...
    'caughtVT', stats.train.caughtVT + stats.test.caughtVT, ...
    'caughtVF', stats.train.caughtVF + stats.test.caughtVF, ...
    'correctVT', stats.train.correctVT + stats.test.correctVT, ...
    'correctVF', stats.train.correctVF + stats.test.correctVF, ...
    'missedVT', stats.train.missedVT + stats.test.missedVT, ...
    'missedVF', stats.train.missedVF + stats.test.missedVF);

report_split('TRAIN records (34, in-sample for Stage 2)', stats.train);
report_split('TEST records (4, held out by Stage 2)', stats.test);
report_split('COMBINED (all 38 records)', combinedStats);

combinedStage2Only = struct( ...
    'totalVT', stage2OnlyStats.train.totalVT + stage2OnlyStats.test.totalVT, ...
    'totalVF', stage2OnlyStats.train.totalVF + stage2OnlyStats.test.totalVF, ...
    'correctVT', stage2OnlyStats.train.correctVT + stage2OnlyStats.test.correctVT, ...
    'correctVF', stage2OnlyStats.train.correctVF + stage2OnlyStats.test.correctVF);

report_stage2_only('STAGE 2 STANDALONE (ungated) -- TRAIN records', stage2OnlyStats.train);
report_stage2_only('STAGE 2 STANDALONE (ungated) -- TEST records', stage2OnlyStats.test);
report_stage2_only('STAGE 2 STANDALONE (ungated) -- COMBINED (all 38)', combinedStage2Only);

%% ---- functions ----

function quantizedValue = quantize_signed_q_format(value, integerBits, fractionBits)
value = double(value);
scale = 2 ^ fractionBits;
qMin = -2 ^ integerBits;
qMax = 2 ^ integerBits - 1 / scale;
quantizedValue = fix(value * scale) / scale;
quantizedValue = min(max(quantizedValue, qMin), qMax);
end

function filteredEcg = apply_causal_pantompkins_highpass(ecg, Fs, highpassHz, filterOrder)
ecg = double(ecg(:));
nyquistHz = Fs / 2;
[b, a] = butter(filterOrder, highpassHz / nyquistHz, 'high');
ecg(~isfinite(ecg)) = 0;
filteredEcg = filter(b, a, ecg);
filteredEcg(~isfinite(filteredEcg)) = 0;
end

function filteredEcg = apply_causal_dc_blocker(ecg, fs, cutoffHz)
ecg = double(ecg(:));
nyquistHz = fs / 2;
[b, a] = butter(1, cutoffHz / nyquistHz, 'high');
filteredEcg = filter(b, a, ecg);
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

function result = interpolate_nonfinite(signal)
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

function report_split(label, s)
fprintf('\n=== %s ===\n', label);
fprintf('True VT windows: %d | True VF windows: %d\n\n', s.totalVT, s.totalVF);

fprintf('Stage 1 gate recall (woke Stage 2 at all):\n');
fprintf('  VT: %d/%d = %.4f\n', s.caughtVT, s.totalVT, s.caughtVT / max(s.totalVT, 1));
fprintf('  VF: %d/%d = %.4f\n\n', s.caughtVF, s.totalVF, s.caughtVF / max(s.totalVF, 1));

fprintf('Stage 2 accuracy, conditional on being gated (Stage 2''s own job):\n');
fprintf('  VT: %d/%d = %.4f\n', s.correctVT, s.caughtVT, s.correctVT / max(s.caughtVT, 1));
fprintf('  VF: %d/%d = %.4f\n\n', s.correctVF, s.caughtVF, s.correctVF / max(s.caughtVF, 1));

fprintf('End-to-end combined accuracy (gated AND correctly classified):\n');
fprintf('  VT: %d/%d = %.4f  (missed by Stage 1: %d)\n', s.correctVT, s.totalVT, s.correctVT / max(s.totalVT, 1), s.missedVT);
fprintf('  VF: %d/%d = %.4f  (missed by Stage 1: %d)\n', s.correctVF, s.totalVF, s.correctVF / max(s.totalVF, 1), s.missedVF);
overallCorrect = s.correctVT + s.correctVF;
overallTotal = s.totalVT + s.totalVF;
fprintf('  Overall: %d/%d = %.4f\n', overallCorrect, overallTotal, overallCorrect / max(overallTotal, 1));
end

function report_stage2_only(label, s2)
fprintf('\n=== %s ===\n', label);
fprintf('  VT accuracy: %d/%d = %.4f\n', s2.correctVT, s2.totalVT, s2.correctVT / max(s2.totalVT, 1));
fprintf('  VF accuracy: %d/%d = %.4f\n', s2.correctVF, s2.totalVF, s2.correctVF / max(s2.totalVF, 1));
overallCorrect = s2.correctVT + s2.correctVF;
overallTotal = s2.totalVT + s2.totalVF;
fprintf('  Overall accuracy: %d/%d = %.4f\n', overallCorrect, overallTotal, overallCorrect / max(overallTotal, 1));
end
