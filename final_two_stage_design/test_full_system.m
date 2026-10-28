%% Full-record, aligned-window test of the two-stage system.
% Inference runs on every 2 s window with a 1 s step, from record time zero.
% Annotation and artifact masks affect scoring only, never inference.
% Stage 1 sequence scoring matches eval_pthighpass_seq_120hz: a complete
% three-window sequence is abnormal when any member window is abnormal.
% This full-stream test retains all eligible normal windows. The original
% evaluator keeps only 25% of MIT-BIH normal windows before building sequences.
% The three final outputs are Other (gate closed), VT, and VF-family.
% The saved model splits differ. Only CUDB/cu13 is held out by both models,
% and it has no VT under Stage 2's label policy. Report VT by split.
% No models are retrained and no validation files are written.

clear;
clc;

thisDir = fileparts(mfilename('fullpath'));
projectRoot = fileparts(thisDir);
databasesRoot = fullfile(projectRoot, "databases");
if ~isfolder(databasesRoot)
    databasesRoot = fullfile(fileparts(projectRoot), "databases");
end
databaseNames = ["mitdb", "vfdb", "cudb"];
databaseFolders = [ ...
    "mit-bih-arrhythmia-database-1.0.0", ...
    "mit-bih-malignant-ventricular-ectopy-database-1.0.0", ...
    "cu-ventricular-tachyarrhythmia-database-1.0.0"];
helperDir = fullfile(projectRoot, "code");
addpath(helperDir);

recordFiles = struct('folder', {}, 'name', {}, 'database', {});
for d = 1:numel(databaseFolders)
    folder = fullfile(databasesRoot, databaseFolders(d));
    if ~isfolder(folder)
        error('Database folder not found: %s', folder);
    end
    files = dir(fullfile(folder, '*.hea'));
    for k = 1:numel(files)
        recordFiles(end + 1).folder = files(k).folder; %#ok<SAGROW>
        recordFiles(end).name = files(k).name;
        recordFiles(end).database = databaseNames(d);
    end
end

analysisFs = 120;
windowSeconds = 2.0;
stepSeconds = 1.0;

%% ---- Load the saved Stage 1 and Stage 2 models ----

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

stage2Spec = jsondecode(fileread(fullfile(thisDir, "stage2", "deliverable", "stage2_hardware_model.json")));
stage2TrainIds = string(stage2Spec.validation.training_records);
stage2TestIds = string(stage2Spec.validation.held_out_records);
artifactTestRecordId = string(stage2Artifacts.test_record_id(:));
artifactTestStart = double(stage2Artifacts.test_start_sample(:));
artifactTestEnd = double(stage2Artifacts.test_end_sample(:));
artifactTestFeatures = double(stage2Artifacts.test_features_python);
artifactTestTruth = double(stage2Artifacts.test_true_label(:));
artifactTestPredicted = double(stage2Artifacts.test_python_predicted_label(:));
if vtLabel ~= 0 || vfLabel ~= 1
    error('Unexpected Stage 2 label encoding.');
end
if numel(recordFiles) ~= numel(union(stage1Data.trainRecordIds, stage1Data.testRecordIds))
    error('Database record list differs from the saved Stage 1 split.');
end

allBinaryTruth = zeros(0, 1);
allClassTruth = zeros(0, 1);
allGate = false(0, 1);
allClassPred = zeros(0, 1);
allStage1Test = false(0, 1);
allStage2Status = zeros(0, 1); % 0=external, 1=train, 2=test
allSequenceTruth = false(0, 1);
allSequenceGate = false(0, 1);
allSequenceStage1Test = false(0, 1);
allSequenceStage2Status = zeros(0, 1);
totalStreamWindows = 0;
totalStreamGateWindows = 0;
parityWindows = 0;
parityMismatches = 0;
parityMaxFeatureDiff = 0;
parityFeatureMaxDiff = zeros(1, numel(combinedWeightQ));
windowLength = round(windowSeconds * analysisFs);
stepLength = round(stepSeconds * analysisFs);

fprintf('Testing %d records from %s on one aligned 120 Hz grid.\n', ...
    numel(recordFiles), databasesRoot);
for r = 1:numel(recordFiles)
    recordName = erase(string(recordFiles(r).name), ".hea");
    recordId = recordFiles(r).database + "/" + recordName;
    recordPath = fullfile(recordFiles(r).folder, recordName);
    stage1Test = ismember(r, stage1Data.testRecordIds);
    if ismember(recordId, stage2TestIds)
        stage2Status = 2;
    elseif ismember(recordId, stage2TrainIds)
        stage2Status = 1;
    else
        stage2Status = 0;
    end

    [ecgRaw, sourceFs, ann, type, comments] = read_ecg_record_212_with_annotations(recordPath);
    ecgRaw = double(ecgRaw(:));
    [binaryLabels, binaryAnnotationMask] = build_normal_abnormal_sample_labels( ...
        numel(ecgRaw), ann, type, comments, recordName, sourceFs, 1.5);
    [classLabels, classAnnotationMask] = build_vt_vf_sample_labels( ...
        numel(ecgRaw), ann, type, comments, recordName, sourceFs, 1.5);
    % Stage 2's training policy treats CUDB brackets as VF and does not
    % use the inferred pre-VF tachycardia lead-in as a VT training label.
    if recordFiles(r).database == "cudb"
        classLabels = cudb_vf_only_labels(numel(ecgRaw), ann, type);
    end
    signalArtifactMask = detect_ecg_signal_artifacts(ecgRaw, sourceFs, 1.5);
    artifactMask = binaryAnnotationMask | classAnnotationMask | signalArtifactMask;
    ecgRaw = interpolate_nonfinite(ecgRaw);
    if abs(sourceFs - analysisFs) > 1e-6
        sourceTime = (0:numel(ecgRaw) - 1)' ./ sourceFs;
        ecgRaw = resample_ecg_only(ecgRaw, sourceFs, analysisFs);
        targetTime = (0:numel(ecgRaw) - 1)' ./ analysisFs;
        binaryLabels = interp1(sourceTime, double(binaryLabels), targetTime, 'nearest', 'extrap');
        classLabels = interp1(sourceTime, double(classLabels), targetTime, 'nearest', 'extrap');
        artifactMask = interp1(sourceTime, double(artifactMask), targetTime, 'nearest', 'extrap') > 0.5;
    end

    ecg1 = quantize_signed_q_format(ecgRaw, stage1QInt, stage1QFrac);
    ecg1 = apply_causal_pantompkins_highpass(ecg1, analysisFs, stage1HighpassHz, stage1HighpassOrder);
    ecg1 = quantize_signed_q_format(ecg1, stage1QInt, stage1QFrac);
    numWindows = floor((numel(ecg1) - windowLength) / stepLength) + 1;
    if numWindows <= 0
        continue;
    end
    X1 = zeros(numWindows, 4);
    binaryTruth = nan(numWindows, 1);
    classTruth = nan(numWindows, 1);
    for w = 1:numWindows
        startIdx = (w - 1) * stepLength + 1;
        endIdx = startIdx + windowLength - 1;
        windowSignal = ecg1(startIdx:endIdx);
        windowMean = quantize_signed_q_format(sum(windowSignal) / windowLength, stage1QInt, stage1QFrac);
        windowSignal = windowSignal - windowMean;
        diffSignal = diff(windowSignal);
        meanAbs = quantize_signed_q_format(sum(abs(windowSignal)) / windowLength, stage1QInt, stage1QFrac);
        zeroCrossings = count_zero_crossings(diffSignal) / windowSeconds;
        lineLength = sum(abs(diffSignal)) / windowSeconds;
        thresholdCrossingCount = count_threshold_crossings(windowSignal, stage1ThresholdFraction);
        X1(w, :) = [meanAbs, zeroCrossings, lineLength, thresholdCrossingCount];

        if mean(artifactMask(startIdx:endIdx)) > 0.01
            continue;
        end
        binaryWindow = binaryLabels(startIdx:endIdx);
        abnormalFraction = mean(binaryWindow == 1);
        if abnormalFraction >= 0.80
            binaryTruth(w) = 1;
        elseif abnormalFraction <= 0.20
            binaryTruth(w) = 0;
        end
        classWindow = classLabels(startIdx:endIdx);
        classFractions = [mean(classWindow == 0), mean(classWindow == 1), mean(classWindow == 2)];
        [majorityFraction, majorityClass] = max(classFractions);
        if majorityFraction >= 0.80
            classTruth(w) = majorityClass - 1;
        end
    end
    [~, scores1] = predict(stage1Model, X1);
    baseAbnormal = scores1(:, 2) >= stage1Threshold;
    voteCount = movsum(double(baseAbnormal), [sequenceLength - 1, 0]);
    gateActive = voteCount >= sequenceVoteThreshold;
    sequenceEligible = movsum(double(isfinite(binaryTruth)), [sequenceLength - 1, 0]) == sequenceLength;
    sequenceEligible(1:min(sequenceLength - 1, numWindows)) = false;
    sequenceTruth = movsum(double(binaryTruth == 1), [sequenceLength - 1, 0]) >= 1;
    allSequenceTruth = [allSequenceTruth; sequenceTruth(sequenceEligible)]; %#ok<AGROW>
    allSequenceGate = [allSequenceGate; gateActive(sequenceEligible)]; %#ok<AGROW>
    allSequenceStage1Test = [allSequenceStage1Test; ...
        repmat(stage1Test, sum(sequenceEligible), 1)]; %#ok<AGROW>
    allSequenceStage2Status = [allSequenceStage2Status; ...
        repmat(stage2Status, sum(sequenceEligible), 1)]; %#ok<AGROW>

    ecg2 = apply_causal_dc_blocker(ecgRaw, analysisFs, 0.1);
    ecg2 = quantize_signed_q_format(ecg2, stage2PostFilterQInt, stage2QFrac);
    ecg2 = apply_causal_bandpass_05_40(ecg2, analysisFs);
    ecg2 = quantize_signed_q_format(ecg2, stage2PostFilterQInt, stage2QFrac);
    for k = find(artifactTestRecordId == recordId)'
        features2 = compute_seven_features( ...
            ecg2(artifactTestStart(k) + 1:artifactTestEnd(k)), ...
            blockLenSamples, stage2ThresholdFraction, deadbandFraction);
        featureDiff = abs(features2 - artifactTestFeatures(k, :));
        parityFeatureMaxDiff = max(parityFeatureMaxDiff, featureDiff);
        parityMaxFeatureDiff = max(parityMaxFeatureDiff, max(featureDiff));
        decision = sum(features2 .* combinedWeightQ) + combinedBiasQ;
        parityMismatches = parityMismatches + ...
            double(double(decision > 0) ~= artifactTestPredicted(k));
        parityWindows = parityWindows + 1;
    end
    classPred = zeros(numWindows, 1); % Gate closed means Other.
    for w = find(gateActive(:))'
        startIdx = (w - 1) * stepLength + 1;
        windowSignal2 = ecg2(startIdx:startIdx + windowLength - 1);
        features2 = compute_seven_features(windowSignal2, blockLenSamples, stage2ThresholdFraction, deadbandFraction);
        decision = sum(features2 .* combinedWeightQ) + combinedBiasQ;
        classPred(w) = 1 + double(decision > 0); % VT=1, VF-family=2.
    end

    scoreMask = isfinite(binaryTruth);
    allBinaryTruth = [allBinaryTruth; binaryTruth(scoreMask)]; %#ok<AGROW>
    allClassTruth = [allClassTruth; classTruth(scoreMask)]; %#ok<AGROW>
    allGate = [allGate; gateActive(scoreMask)]; %#ok<AGROW>
    allClassPred = [allClassPred; classPred(scoreMask)]; %#ok<AGROW>
    allStage1Test = [allStage1Test; repmat(stage1Test, sum(scoreMask), 1)]; %#ok<AGROW>
    allStage2Status = [allStage2Status; repmat(stage2Status, sum(scoreMask), 1)]; %#ok<AGROW>
    totalStreamWindows = totalStreamWindows + numWindows;
    totalStreamGateWindows = totalStreamGateWindows + sum(gateActive);
end

fprintf('\nAll streamed windows: %d; gate active: %d (%.2f%%)\n', ...
    totalStreamWindows, totalStreamGateWindows, 100 * totalStreamGateWindows / totalStreamWindows);
fprintf('Stage 2 artifact parity: %d windows, %d prediction mismatches, max feature difference %.6g\n', ...
    parityWindows, parityMismatches, parityMaxFeatureDiff);
fprintf('Stage 2 max difference by feature: %s\n', mat2str(parityFeatureMaxDiff, 6));
if parityWindows ~= numel(artifactTestTruth) || parityMismatches ~= 0
    warning('Stage 2 inference does not reproduce all saved artifact test predictions.');
end
artifactVT = artifactTestTruth == vtLabel;
artifactVF = artifactTestTruth == vfLabel;
fprintf('Standalone Stage 2 artifact recall: VT %d/%d = %.4f; VF %d/%d = %.4f\n', ...
    sum(artifactVT & artifactTestPredicted == vtLabel), sum(artifactVT), ...
    sum(artifactVT & artifactTestPredicted == vtLabel) / max(sum(artifactVT), 1), ...
    sum(artifactVF & artifactTestPredicted == vfLabel), sum(artifactVF), ...
    sum(artifactVF & artifactTestPredicted == vfLabel) / max(sum(artifactVF), 1));
fprintf('Stage 1 sequence scoring uses all eligible windows; original evaluator keeps only 25%% of MIT-BIH normal windows.\n');
report_sequence_gate('ALL RECORDS (mixed training status)', true(size(allSequenceGate)), ...
    allSequenceTruth, allSequenceGate);
report_sequence_gate('STAGE 1 TEST RECORDS', allSequenceStage1Test, ...
    allSequenceTruth, allSequenceGate);
report_sequence_gate('STAGE 2 TEST RECORDS', allSequenceStage2Status == 2, ...
    allSequenceTruth, allSequenceGate);
report_full_system('ALL RECORDS (descriptive, mixed training status)', true(size(allGate)), ...
    allBinaryTruth, allClassTruth, allGate, allClassPred);
report_full_system('STAGE 2 TEST RECORDS (Stage 1 split mixed)', allStage2Status == 2, ...
    allBinaryTruth, allClassTruth, allGate, allClassPred);
report_full_system('BOTH MODELS HELD OUT (CUDB/cu13; VF only)', allStage1Test & allStage2Status == 2, ...
    allBinaryTruth, allClassTruth, allGate, allClassPred);
report_full_system('STAGE 1 TEST RECORDS (Stage 2 split mixed)', allStage1Test, ...
    allBinaryTruth, allClassTruth, allGate, allClassPred);
report_full_system('STAGE 2 TRAIN RECORDS (in sample)', allStage2Status == 1, ...
    allBinaryTruth, allClassTruth, allGate, allClassPred);
report_full_system('STAGE 1 TEST / STAGE 2 TRAIN (in sample for Stage 2)', allStage1Test & allStage2Status == 1, ...
    allBinaryTruth, allClassTruth, allGate, allClassPred);
report_full_system('STAGE 2 TEST / STAGE 1 TRAIN (in sample for Stage 1)', ~allStage1Test & allStage2Status == 2, ...
    allBinaryTruth, allClassTruth, allGate, allClassPred);
report_full_system('STAGE 1 TEST / STAGE 2 EXTERNAL (outside Stage 2 cohort)', allStage1Test & allStage2Status == 0, ...
    allBinaryTruth, allClassTruth, allGate, allClassPred);

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

function labels = cudb_vf_only_labels(numSamples, ann, type)
labels = zeros(numSamples, 1);
ann = max(1, min(numSamples, double(ann(:))));
type = type(:);
openStart = [];
for k = 1:numel(ann)
    if type(k) == '['
        openStart = ann(k);
    elseif type(k) == ']' && ~isempty(openStart)
        labels(openStart:ann(k)) = 2;
        openStart = [];
    end
end
if ~isempty(openStart)
    labels(openStart:end) = 2;
end
end

function report_sequence_gate(label, rows, truth, gate)
truth = truth(rows);
gate = gate(rows);
fprintf('\n=== STAGE 1 + 2-OF-3 SEQUENCE: %s ===\n', label);
if isempty(truth)
    fprintf('No complete clean sequences.\n');
    return;
end
tn = sum(~truth & ~gate);
fp = sum(~truth & gate);
fn = sum(truth & ~gate);
tp = sum(truth & gate);
precision = tp / max(tp + fp, 1);
recall = tp / max(tp + fn, 1);
f1 = 2 * tp / max(2 * tp + fp + fn, 1);
fprintf('Sequences: %d; truth abnormal if any of 3 windows is abnormal\n', numel(truth));
fprintf('[TN FP; FN TP] = [%d %d; %d %d]\n', tn, fp, fn, tp);
fprintf('Accuracy %.4f; precision %.4f; recall %.4f; F1 %.4f\n', ...
    (tn + tp) / numel(truth), precision, recall, f1);
end

function report_full_system(label, rows, binaryTruth, classTruth, gate, classPred)
binaryTruth = binaryTruth(rows);
classTruth = classTruth(rows);
gate = gate(rows);
classPred = classPred(rows);
fprintf('\n=== %s ===\n', label);
if isempty(binaryTruth)
    fprintf('No scored windows.\n');
    return;
end
tn = sum(binaryTruth == 0 & ~gate);
fp = sum(binaryTruth == 0 & gate);
fn = sum(binaryTruth == 1 & ~gate);
tp = sum(binaryTruth == 1 & gate);
fprintf('Clean, binary-labeled windows: %d; gate active: %d (%.2f%%)\n', ...
    numel(binaryTruth), sum(gate), 100 * mean(gate));
fprintf('Current-window gate [TN FP; FN TP] = [%d %d; %d %d], accuracy %.4f, precision %.4f, recall %.4f\n', ...
    tn, fp, fn, tp, (tn + tp) / numel(binaryTruth), tp / max(tp + fp, 1), tp / max(tp + fn, 1));

valid = isfinite(classTruth);
classTruth = classTruth(valid);
classPred = classPred(valid);
gate = gate(valid);
if isempty(classTruth)
    fprintf('No clean three-class windows.\n');
    return;
end
cm = zeros(3, 3);
for truth = 0:2
    for predicted = 0:2
        cm(truth + 1, predicted + 1) = sum(classTruth == truth & classPred == predicted);
    end
end
fprintf('Three-class windows: %d; accuracy %.4f\n', numel(classTruth), trace(cm) / numel(classTruth));
fprintf('Confusion rows=true, columns=predicted [Other VT VF]:\n');
disp(cm);
for truth = 0:2
    total = sum(cm(truth + 1, :));
    if total == 0
        fprintf('Class %d: no labeled windows in this group\n', truth);
        continue;
    end
    caught = sum(classTruth == truth & gate);
    correct = cm(truth + 1, truth + 1);
    fprintf('Class %d: support=%d, end-to-end recall=%d/%d = %.4f', ...
        truth, total, correct, total, correct / max(total, 1));
    if truth > 0
        fprintf(', gate recall=%d/%d = %.4f, Stage 2 given gate=%d/%d = %.4f', ...
            caught, total, caught / max(total, 1), correct, caught, correct / max(caught, 1));
    end
    fprintf('\n');
end
end
