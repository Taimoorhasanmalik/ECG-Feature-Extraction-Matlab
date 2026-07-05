%% Evaluate hard-rule sequence count gate with causal Pan-Tompkins bandpass fix-mean-only Q3.8 base model
% Abnormal = VT or VF rhythm. All other rhythms are treated as Normal.
% This evaluator keeps the trained Stage 1 fix-mean-only Q3.8 window SVM,
% then replaces the sequence-level SVM with a fixed count rule:
%
%   sequence is Abnormal when abnormal_vote_count >= threshold
%
% The preprocessing matches train_q38_recall90_guard98_gate_fix_q38_meanonly_ptbandpass:
% initial ECG Q3.8 uses fix(), and only window mean values are Q3.8-truncated
% after sum/windowLength division.

clear;
clc;
close all;

rng(7);

scriptDir = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
databaseNames = ["mitdb", "vfdb", "cudb"];
databaseSelection = strtrim(string(getenv('ECG_TRAIN_DATABASES')));
if strlength(databaseSelection) > 0
    databaseNames = strtrim(split(databaseSelection, ',')).';
    databaseNames = databaseNames(strlength(databaseNames) > 0);
end
databasePathSelection = strtrim(string(getenv('ECG_TRAIN_DATABASE_PATHS')));
if strlength(databasePathSelection) > 0
    dataFolders = strtrim(split(databasePathSelection, pathsep)).';
    dataFolders = dataFolders(strlength(dataFolders) > 0);
else
    localDatabaseRoot = fullfile(projectRoot, "databases");
    dataFolders = database_folders_from_names(localDatabaseRoot, databaseNames);
    if isempty(dataFolders)
        dataFolders = fullfile(projectRoot, "Database", databaseNames);
    end
    dataFolders = dataFolders(arrayfun(@(p) exist(p, 'dir') == 7, dataFolders));
end
if isempty(dataFolders)
    thesisRoot = fileparts(projectRoot);
    dataFolders = [
        fullfile(thesisRoot, "databases", "mit-bih-arrhythmia-database-1.0.0"), ...
        fullfile(thesisRoot, "databases", "mit-bih-malignant-ventricular-ectopy-database-1.0.0"), ...
        fullfile(thesisRoot, "databases", "cu-ventricular-tachyarrhythmia-database-1.0.0")];
    dataFolders = dataFolders(arrayfun(@(p) exist(p, 'dir') == 7, dataFolders));
end
if isempty(dataFolders)
    dataFolders = database_folders_from_names(fullfile(projectRoot, "databases"), databaseNames);
end
modelFolder = fullfile(projectRoot, "models");
targetSampleRateHz = 120;
targetSampleRateSelection = strtrim(string(getenv('ECG_TARGET_SAMPLE_RATE_HZ')));
if strlength(targetSampleRateSelection) > 0
    targetSampleRateHz = str2double(targetSampleRateSelection);
    if ~isfinite(targetSampleRateHz) || targetSampleRateHz <= 0
        error('ECG_TARGET_SAMPLE_RATE_HZ must be a positive numeric sample rate.');
    end
end
sampleRateSuffix = "";
if ~isempty(targetSampleRateHz)
    sampleRateSuffix = sprintf("_%ghz", targetSampleRateHz);
end
cleanTrainingEnabled = false;
modelStem = "stage1_q38_sequence3_iterative_lsvm";
modelStem = modelStem + sampleRateSuffix;
sequenceModelStem = modelStem;
if isequal(sort(databaseNames), sort(["mitdb", "vfdb", "cudb"]))
    modelFile = fullfile(modelFolder, modelStem + ".mat");
else
    sequenceModelStem = sprintf("%s_%s", modelStem, strjoin(databaseNames, "_"));
    modelFile = fullfile(modelFolder, sprintf("%s_%s.mat", modelStem, ...
        strjoin(databaseNames, "_")));
end

windowSeconds = 2.0;
stepSeconds = 1.0;
sequenceLength = 3;
sequenceLabelMinAbnormalWindows = 1;
mitdbNormalKeepFraction = 0.25;
mitdbNormalKeepSeed = 31;
minWindowClassFraction = 0.80;
normalToAbnormalRatio = 1.0;
normalToAbnormalRatioCandidates = [1, 2, 3, 4];
numFolds = 5;
boxConstraint = 1;
boxConstraintCandidates = [0.1, 0.3, 1, 3, 10];
thresholdFraction = 0.20;
artifactPadSeconds = 1.5;
artifactMaxWindowFraction = 0.01;
featureOutlierZLimit = 8.0;
svmKernel = 'linear';
kernelScale = 'auto';
useGPURequested = true;
thresholdObjective = 'accuracy_recall_floor';
thresholdObjectiveCandidates = {'accuracy_recall_floor'};
minRecallForAccuracy = 0.90;
classWeightMode = 'balanced';
classWeightModeCandidates = {'balanced', 'none'};
abnormalAugmentationFactor = 1.0;
abnormalAugmentationFactorSelection = strtrim(string(getenv('ECG_ABNORMAL_AUGMENTATION_FACTOR')));
if strlength(abnormalAugmentationFactorSelection) > 0
    abnormalAugmentationFactor = str2double(abnormalAugmentationFactorSelection);
    if ~isfinite(abnormalAugmentationFactor) || abnormalAugmentationFactor < 0
        error('ECG_ABNORMAL_AUGMENTATION_FACTOR must be a nonnegative numeric value.');
    end
end
abnormalAugmentationSeed = 23;
abnormalAugmentationSeedSelection = strtrim(string(getenv('ECG_ABNORMAL_AUGMENTATION_SEED')));
if strlength(abnormalAugmentationSeedSelection) > 0
    abnormalAugmentationSeed = str2double(abnormalAugmentationSeedSelection);
    if ~isfinite(abnormalAugmentationSeed)
        error('ECG_ABNORMAL_AUGMENTATION_SEED must be numeric.');
    end
end
testFraction = 0.20;
testFractionSelection = strtrim(string(getenv('ECG_TEST_FRACTION')));
if strlength(testFractionSelection) > 0
    testFraction = str2double(testFractionSelection);
    if ~isfinite(testFraction) || testFraction <= 0 || testFraction >= 1
        error('ECG_TEST_FRACTION must be a numeric value between 0 and 1.');
    end
end
trainTestSplitSeed = 17;
trainTestSplitSeedSelection = strtrim(string(getenv('ECG_TRAIN_TEST_SPLIT_SEED')));
if strlength(trainTestSplitSeedSelection) > 0
    trainTestSplitSeed = str2double(trainTestSplitSeedSelection);
    if ~isfinite(trainTestSplitSeed)
        error('ECG_TRAIN_TEST_SPLIT_SEED must be numeric.');
    end
end
quantizationFormat = 'Q3.8_fix_meanonly';
quantizationRoundingMode = 'fix';
quantizationStageMode = 'signal_ptbandpass_and_window_mean_only';
quantizationIntegerBits = 3;
quantizationFractionBits = 8;
quantizationScale = 2 ^ quantizationFractionBits;
quantizationMin = -2 ^ quantizationIntegerBits;
quantizationMax = 2 ^ quantizationIntegerBits - 1 / quantizationScale;
preprocessingMode = 'causal_pantompkins_bandpass';
preprocessingBandpassLowHz = 5;
preprocessingBandpassHighHz = 15;
preprocessingBandpassOrder = 3;

baseModelFile = fullfile(modelFolder, ...
    "stage1_normal_vs_abnormal_window_quantized_q3_8_fix_meanonly_ptbandpass_recall90_guard98_robust_lsvm" + ...
    sampleRateSuffix + "_without_rms_amplitude_robust_range.mat");
baseModelSelection = strtrim(string(getenv('ECG_BASE_WINDOW_MODEL_FILE')));
if strlength(baseModelSelection) > 0
    baseModelFile = baseModelSelection;
end

sequenceFeatureVariants = struct( ...
    'stem', {'count', 'count_max', 'count_max_sum', 'count_max_sum_delta', ...
    'count_max_sum_delta_min'}, ...
    'featureMask', {[true false false false false], [true true false false false], ...
    [true true true false false], [true true true true false], ...
    [true true true true true]});
sequenceAllFeatureNames = {'abnormal_vote_count', 'max_score', 'sum_score', ...
    'score_delta', 'min_score'};
sequenceVariantSelection = strtrim(string(getenv('ECG_SEQUENCE_VARIANTS')));
if strlength(sequenceVariantSelection) > 0
    requestedVariantStems = strtrim(split(sequenceVariantSelection, ','));
    requestedVariantStems = requestedVariantStems(strlength(requestedVariantStems) > 0);
    availableVariantStems = string({sequenceFeatureVariants.stem});
    unknownVariantStems = setdiff(requestedVariantStems, availableVariantStems);
    if ~isempty(unknownVariantStems)
        error('Unknown ECG_SEQUENCE_VARIANTS value(s): %s', strjoin(unknownVariantStems, ', '));
    end
    sequenceFeatureVariants = sequenceFeatureVariants(ismember(availableVariantStems, requestedVariantStems));
end

allFeatureNames = {'mean_abs', 'zero_crossings', 'line_length', 'threshold_crossing_count', ...
    'rms_amplitude', 'robust_range'};
excludedFeatureNames = ["rms_amplitude"; "robust_range"];
excludedFeatureSelection = strtrim(string(getenv('ECG_EXCLUDE_FEATURES')));
if strlength(excludedFeatureSelection) > 0
    excludedFeatureNames = strtrim(split(excludedFeatureSelection, ','));
    excludedFeatureNames = excludedFeatureNames(strlength(excludedFeatureNames) > 0);
end
selectedFeatureMask = ~ismember(string(allFeatureNames), excludedFeatureNames);
unknownExcludedFeatures = setdiff(excludedFeatureNames, string(allFeatureNames));
if ~isempty(unknownExcludedFeatures)
    error('Unknown ECG_EXCLUDE_FEATURES value(s): %s', strjoin(unknownExcludedFeatures, ', '));
end
if ~any(selectedFeatureMask)
    error('At least one feature must remain after ECG_EXCLUDE_FEATURES filtering.');
end
featureNames = allFeatureNames(selectedFeatureMask);
labelNames = {'Normal', 'Abnormal'};

if ~isempty(excludedFeatureNames)
    excludedFeatureSuffix = "_without_" + strjoin(excludedFeatureNames, "_");
    excludedFeatureSuffix = regexprep(lower(excludedFeatureSuffix), '[^a-z0-9_]+', '_');
    [modelFolderPart, modelBaseName, modelExt] = fileparts(modelFile);
    modelFile = fullfile(modelFolderPart, modelBaseName + excludedFeatureSuffix + modelExt);
end

% Exclude records identified by the per-record validation run as likely
% label/noise/domain outliers: accuracy < 50% or abnormal recall < 60%.
problematicRecordKeys = ["mitdb/107", "mitdb/213", "mitdb/223", ...
    "vfdb/418", "vfdb/419", "vfdb/429", "vfdb/615", ...
    "cudb/cu02", "cudb/cu03", "cudb/cu05", "cudb/cu08", "cudb/cu09", ...
    "cudb/cu11", "cudb/cu12", "cudb/cu13", "cudb/cu14", "cudb/cu17", ...
    "cudb/cu18", "cudb/cu19", "cudb/cu21", "cudb/cu25", "cudb/cu27", ...
    "cudb/cu28", "cudb/cu29", "cudb/cu32", "cudb/cu33"];
excludedRecordKeys = strings(0, 1);
excludedRecordReasons = strings(0, 1);

recordFiles = struct('folder', {}, 'name', {});
for folderIdx = 1:length(dataFolders)
    folderRecords = dir(fullfile(dataFolders(folderIdx), '*.hea'));
    for recordIdx = 1:length(folderRecords)
        recordFiles(end + 1).folder = folderRecords(recordIdx).folder; %#ok<SAGROW>
        recordFiles(end).name = folderRecords(recordIdx).name;
    end
end

all_X = [];
all_Y = [];
all_record_ids = [];
all_window_numbers = [];
all_database_aliases = strings(0, 1);

fprintf('\nNormal vs Abnormal Q3.8 fix-mean-only hard-rule sequence-count evaluator\n');
fprintf('Folders:\n');
for folderIdx = 1:length(dataFolders)
    fprintf('  %s\n', dataFolders(folderIdx));
end
if ~isempty(targetSampleRateHz)
    fprintf('Target sample rate: %.2f Hz\n', targetSampleRateHz);
else
    fprintf('Target sample rate: native record sampling rates\n');
end
fprintf('Window: %.2f sec | Step: %.2f sec | Clean-label fraction: %.2f\n', ...
    windowSeconds, stepSeconds, minWindowClassFraction);
fprintf('Sequence length: %d consecutive windows | abnormal label needs >= %d abnormal window(s)\n', ...
    sequenceLength, sequenceLabelMinAbnormalWindows);
fprintf('MIT-BIH arrhythmia normal-window keep fraction before hard-rule evaluation: %.2f\n', ...
    mitdbNormalKeepFraction);
fprintf('Quantization: %s | range [%.6g, %.6g] | step %.6g\n', ...
    quantizationFormat, quantizationMin, quantizationMax, 1 / quantizationScale);
fprintf('Initial ECG uses %s(ecg * scale) / scale; feature stage quantizes only window means after sum/windowLength division.\n', ...
    quantizationRoundingMode);
fprintf('Preprocessing: causal Pan-Tompkins-style %.1f-%.1f Hz bandpass, order %d, no whole-record median removal.\n', ...
    preprocessingBandpassLowHz, preprocessingBandpassHighHz, preprocessingBandpassOrder);
fprintf('Base window model: %s\n', baseModelFile);
fprintf('Record-level holdout test fraction: %.2f | split seed: %g\n', ...
    testFraction, trainTestSplitSeed);
fprintf('Artifact padding: %.2f sec | Max artifact window fraction: %.3f | Feature outlier z-limit: %.2f\n', ...
    artifactPadSeconds, artifactMaxWindowFraction, featureOutlierZLimit);
fprintf('Sequence decision: hard count rule, no sequence-level SVM training.\n');
fprintf('Selected features (%d): %s\n', numel(featureNames), strjoin(string(featureNames), ', '));
if ~isempty(excludedFeatureNames)
    fprintf('Excluded features: %s\n', strjoin(excludedFeatureNames, ', '));
end
if cleanTrainingEnabled
    fprintf('Clean training enabled: excluding defibrillation/shock records and %d problematic records.\n', ...
        numel(problematicRecordKeys));
    fprintf('Clean model output: %s\n', modelFile);
end
if exist(baseModelFile, 'file') ~= 2
    error('Base window model was not found: %s', baseModelFile);
end
if exist('fitcsvm', 'file') == 2
    svmImplementation = "fitcsvm";
else
    svmImplementation = "linear_svm_fallback";
end
if useGPURequested
    if ~strcmpi(svmKernel, 'linear')
        error('GPU prediction is requested, but only the linear SVM GPU path is supported.');
    end
    if svmImplementation ~= "fitcsvm"
        error('GPU prediction is requested, but fitcsvm is unavailable.');
    end
    if ~can_use_gpu_arrays()
        error('GPU prediction is requested, but MATLAB cannot access a GPU. Check Parallel Computing Toolbox and gpuDevice.');
    end
    useGPUTraining = true;
    fprintf('GPU prediction requested: available, will use batched gpuArray predict.\n');
else
    useGPUTraining = false;
end
if ~useGPUTraining && svmImplementation == "linear_svm_fallback"
    fprintf('fitcsvm unavailable, using local linear SVM fallback.\n');
elseif ~useGPUTraining
    fprintf('GPU prediction unavailable or disabled for this kernel, using CPU predict.\n');
end

for fileIdx = 1:length(recordFiles)
    recordBase = recordFiles(fileIdx).name(1:end-4);
    recordname = char(fullfile(recordFiles(fileIdx).folder, recordBase));
    [~, databaseName] = fileparts(recordFiles(fileIdx).folder);
    databaseAlias = database_alias_from_folder(databaseName);
    recordKey = string(databaseName) + "/" + string(recordBase);

    if cleanTrainingEnabled && any(problematicRecordKeys == recordKey)
        fprintf('\nSkipping %s: marked as problematic by per-record validation.\n', recordKey);
        excludedRecordKeys(end + 1, 1) = recordKey; %#ok<SAGROW>
        excludedRecordReasons(end + 1, 1) = "problematic_validation_record"; %#ok<SAGROW>
        continue;
    end

    fprintf('\nReading ECG signal from file: %s\n', recordname);

    try
        [ecg, Fs, ann, type, comments] = read_record_with_fallback(recordname);
    catch ME
        warning('Skipping %s because it could not be read: %s', recordBase, ME.message);
        continue;
    end

    if isempty(ecg) || isempty(ann)
        warning('Skipping %s because ECG or annotations are empty.', recordBase);
        continue;
    end

    if cleanTrainingEnabled && is_defibrillation_record(comments)
        fprintf('Skipping %s: annotation comments contain defibrillation/shock markers.\n', recordKey);
        excludedRecordKeys(end + 1, 1) = recordKey; %#ok<SAGROW>
        excludedRecordReasons(end + 1, 1) = "defibrillation_or_shock"; %#ok<SAGROW>
        continue;
    end

    ecg = double(ecg(:));
    [sampleLabels, annotationArtifactMask] = build_normal_abnormal_labels( ...
        length(ecg), ann, type, comments, recordBase, Fs, artifactPadSeconds);
    signalArtifactMask = detect_signal_artifacts(ecg, Fs, artifactPadSeconds);
    artifactMask = annotationArtifactMask | signalArtifactMask;

    if ~isempty(targetSampleRateHz) && abs(Fs - targetSampleRateHz) > eps
        [ecg, sampleLabels, artifactMask] = resample_signal_labels_and_mask( ...
            ecg, sampleLabels, artifactMask, Fs, targetSampleRateHz);
        Fs = targetSampleRateHz;
    end
    ecg = quantize_signed_q_format(ecg, quantizationIntegerBits, quantizationFractionBits);
    ecg = apply_causal_pantompkins_bandpass(ecg, Fs, preprocessingBandpassLowHz, ...
        preprocessingBandpassHighHz, preprocessingBandpassOrder);
    ecg = quantize_signed_q_format(ecg, quantizationIntegerBits, quantizationFractionBits);

    [X_file, Y_file, W_file] = extract_window_features(ecg, sampleLabels, Fs, ...
        windowSeconds, stepSeconds, minWindowClassFraction, thresholdFraction, ...
        artifactMask, artifactMaxWindowFraction, quantizationIntegerBits, ...
        quantizationFractionBits);

    if isempty(Y_file)
        fprintf('No clean windows extracted from %s.\n', recordBase);
        continue;
    end

    if databaseAlias == "mitdb" && mitdbNormalKeepFraction < 1
        rng(mitdbNormalKeepSeed + fileIdx);
        normalIdx = find(Y_file == 0);
        abnormalIdx = find(Y_file == 1);
        originalNormalCount = numel(normalIdx);
        keepNormalCount = max(0, round(mitdbNormalKeepFraction * numel(normalIdx)));
        if keepNormalCount < numel(normalIdx)
            normalIdx = normalIdx(randperm(numel(normalIdx), keepNormalCount));
        end
        keepIdx = sort([abnormalIdx; normalIdx]);
        X_file = X_file(keepIdx, :);
        Y_file = Y_file(keepIdx);
        W_file = W_file(keepIdx);
        fprintf('MIT-BIH normal-window reduction kept %d/%d normal windows.\n', ...
            sum(Y_file == 0), originalNormalCount);
    end

    all_X = [all_X; X_file];
    all_Y = [all_Y; Y_file];
    all_record_ids = [all_record_ids; repmat(fileIdx, length(Y_file), 1)];
    all_window_numbers = [all_window_numbers; W_file];
    all_database_aliases = [all_database_aliases; repmat(databaseAlias, length(Y_file), 1)];

    fprintf('Windows: %d | Abnormal: %d | Normal: %d\n', ...
        length(Y_file), sum(Y_file == 1), sum(Y_file == 0));
end

if isempty(all_Y)
    error('No training windows were extracted. Check database paths and annotations.');
end

X = all_X;
Y = all_Y;
record_ids = all_record_ids;
window_numbers = all_window_numbers;
database_aliases = all_database_aliases;
X = X(:, selectedFeatureMask);

validRows = all(isfinite(X), 2) & isfinite(Y);
X = X(validRows, :);
Y = Y(validRows);
record_ids = record_ids(validRows);
window_numbers = window_numbers(validRows);
database_aliases = database_aliases(validRows);

numRowsBeforeOutlierRemoval = length(Y);
[X, Y, record_ids, outlierKeep] = remove_feature_outliers(X, Y, record_ids, featureOutlierZLimit);
window_numbers = window_numbers(outlierKeep);
database_aliases = database_aliases(outlierKeep);
fprintf('\nFeature outlier removal skipped %d/%d windows.\n', ...
    numRowsBeforeOutlierRemoval - sum(outlierKeep), numRowsBeforeOutlierRemoval);

fprintf('\nRaw window dataset:\n');
print_dataset_stats(Y);
fprintf('\nExcluded records: %d\n', numel(excludedRecordKeys));
if ~isempty(excludedRecordKeys)
    excludedRecords = table(excludedRecordKeys, excludedRecordReasons, ...
        'VariableNames', {'record', 'reason'});
    disp(excludedRecords);
else
    excludedRecords = table(strings(0, 1), strings(0, 1), ...
        'VariableNames', {'record', 'reason'});
end

raw_X = X;
raw_Y = Y;
raw_record_ids = record_ids;
raw_window_numbers = window_numbers;
raw_database_aliases = database_aliases;

[trainRows, testRows, trainRecordIds, testRecordIds] = split_records_for_holdout( ...
    raw_Y, raw_record_ids, testFraction, trainTestSplitSeed);

train_X_raw = raw_X(trainRows, :);
train_Y_raw = raw_Y(trainRows);
train_record_ids_raw = raw_record_ids(trainRows);
train_window_numbers_raw = raw_window_numbers(trainRows);
train_database_aliases_raw = raw_database_aliases(trainRows);
test_X = raw_X(testRows, :);
test_Y = raw_Y(testRows);
test_record_ids = raw_record_ids(testRows);
test_window_numbers = raw_window_numbers(testRows);
test_database_aliases = raw_database_aliases(testRows);

fprintf('\nRecord-level train/test split:\n');
fprintf('Train records: %d | Test records: %d\n', numel(trainRecordIds), numel(testRecordIds));
fprintf('\nRaw training-window dataset:\n');
print_dataset_stats(train_Y_raw);
fprintf('\nUntouched holdout test-window dataset:\n');
print_dataset_stats(test_Y);

if numel(unique(train_Y_raw)) < 2
    error('Training split requires both Normal and Abnormal windows.');
end
if numel(unique(test_Y)) < 2
    warning('Holdout test split does not contain both classes; metrics may be incomplete.');
end

baseModelData = load(baseModelFile);
baseWindowModel = baseModelData.normal_abnormal_svm_model;
baseDecisionThreshold = baseModelData.decisionThreshold;

fprintf('\nScoring windows with base model...\n');
baseTestScores = predict_scores_optional_gpu(baseWindowModel, test_X, useGPUTraining);

[testSequenceAll_X, testSequence_Y, testSequence_record_ids] = make_sequence_gate_features( ...
    baseTestScores(:, 2), test_Y, test_record_ids, test_window_numbers, ...
    sequenceLength, sequenceLabelMinAbnormalWindows, baseDecisionThreshold);

fprintf('\nUntouched holdout test-sequence dataset:\n');
print_dataset_stats(testSequence_Y);

if numel(unique(testSequence_Y)) < 2
    warning('Holdout test split does not contain both sequence classes; metrics may be incomplete.');
end

hardRuleThresholds = 1:sequenceLength;
hardRuleThresholdSelection = strtrim(string(getenv('ECG_HARD_RULE_COUNT_THRESHOLDS')));
if strlength(hardRuleThresholdSelection) > 0
    hardRuleThresholds = str2double(strtrim(split(hardRuleThresholdSelection, ','))).';
    if any(~isfinite(hardRuleThresholds)) || any(hardRuleThresholds < 1) || ...
            any(hardRuleThresholds > sequenceLength) || any(floor(hardRuleThresholds) ~= hardRuleThresholds)
        error('ECG_HARD_RULE_COUNT_THRESHOLDS must contain integer thresholds from 1 to sequenceLength.');
    end
end

abnormalVoteCounts = testSequenceAll_X(:, 1);
ruleScores = abnormalVoteCounts;

fprintf('\nBase model:\n  %s\n', baseModelFile);
fprintf('Base decision threshold: %.9f\n', baseDecisionThreshold);
fprintf('Sequence feature: abnormal_vote_count over %d consecutive windows\n', sequenceLength);
fprintf('Hard-rule thresholds: %s\n', mat2str(hardRuleThresholds));

hardRuleSummary = struct('rule', {}, 'threshold', {}, ...
    'accuracy', {}, 'precision', {}, 'recall', {}, 'f1_score', {}, 'auc', {}, ...
    'TN', {}, 'FP', {}, 'FN', {}, 'TP', {}, 'invocationRate', {});

for thresholdIdx = 1:numel(hardRuleThresholds)
    countThreshold = hardRuleThresholds(thresholdIdx);
    rulePred = double(abnormalVoteCounts >= countThreshold);
    holdoutTestMetrics = binary_metrics(testSequence_Y, rulePred, ruleScores);
    invocationRate = mean(rulePred == 1);

    fprintf('\nHard rule: abnormal_vote_count >= %d\n', countThreshold);
    fprintf('Sequences: %d | Abnormal: %d | Normal: %d | Invocation rate: %.2f%%\n', ...
        length(testSequence_Y), sum(testSequence_Y == 1), sum(testSequence_Y == 0), ...
        invocationRate * 100);
    fprintf('Accuracy: %.2f%% | Precision: %.4f | Recall: %.4f | F1: %.4f | AUC(count): %.4f\n', ...
        holdoutTestMetrics.accuracy * 100, holdoutTestMetrics.precision, ...
        holdoutTestMetrics.recall, holdoutTestMetrics.f1_score, holdoutTestMetrics.auc);
    fprintf('Confusion Matrix [TN FP; FN TP]:\n');
    disp([holdoutTestMetrics.TN holdoutTestMetrics.FP; holdoutTestMetrics.FN holdoutTestMetrics.TP]);

    summaryIdx = numel(hardRuleSummary) + 1;
    hardRuleSummary(summaryIdx).rule = sprintf("count_ge_%d", countThreshold);
    hardRuleSummary(summaryIdx).threshold = countThreshold;
    hardRuleSummary(summaryIdx).accuracy = holdoutTestMetrics.accuracy;
    hardRuleSummary(summaryIdx).precision = holdoutTestMetrics.precision;
    hardRuleSummary(summaryIdx).recall = holdoutTestMetrics.recall;
    hardRuleSummary(summaryIdx).f1_score = holdoutTestMetrics.f1_score;
    hardRuleSummary(summaryIdx).auc = holdoutTestMetrics.auc;
    hardRuleSummary(summaryIdx).TN = holdoutTestMetrics.TN;
    hardRuleSummary(summaryIdx).FP = holdoutTestMetrics.FP;
    hardRuleSummary(summaryIdx).FN = holdoutTestMetrics.FN;
    hardRuleSummary(summaryIdx).TP = holdoutTestMetrics.TP;
    hardRuleSummary(summaryIdx).invocationRate = invocationRate;
end

fprintf('\nHard-rule holdout summary:\n');
for summaryIdx = 1:numel(hardRuleSummary)
    fprintf('  %s | acc %.2f%% | precision %.4f | recall %.4f | F1 %.4f | AUC(count) %.4f | invoke %.2f%% | [TN FP; FN TP] = [%d %d; %d %d]\n', ...
        hardRuleSummary(summaryIdx).rule, hardRuleSummary(summaryIdx).accuracy * 100, ...
        hardRuleSummary(summaryIdx).precision, hardRuleSummary(summaryIdx).recall, ...
        hardRuleSummary(summaryIdx).f1_score, hardRuleSummary(summaryIdx).auc, ...
        hardRuleSummary(summaryIdx).invocationRate * 100, hardRuleSummary(summaryIdx).TN, ...
        hardRuleSummary(summaryIdx).FP, hardRuleSummary(summaryIdx).FN, hardRuleSummary(summaryIdx).TP);
end

function alias = database_alias_from_folder(databaseName)
databaseName = lower(string(databaseName));
if contains(databaseName, "arrhythmia") || contains(databaseName, "mitdb")
    alias = "mitdb";
elseif contains(databaseName, "malignant") || contains(databaseName, "vfdb")
    alias = "vfdb";
elseif contains(databaseName, "tachyarrhythmia") || contains(databaseName, "cudb")
    alias = "cudb";
else
    alias = databaseName;
end
end

function folders = database_folders_from_names(databaseRoot, databaseNames)
folderNames = strings(size(databaseNames));
for idx = 1:numel(databaseNames)
    switch lower(strtrim(string(databaseNames(idx))))
        case "mitdb"
            folderNames(idx) = "mit-bih-arrhythmia-database-1.0.0";
        case "vfdb"
            folderNames(idx) = "mit-bih-malignant-ventricular-ectopy-database-1.0.0";
        case "cudb"
            folderNames(idx) = "cu-ventricular-tachyarrhythmia-database-1.0.0";
        otherwise
            folderNames(idx) = string(databaseNames(idx));
    end
end

folders = fullfile(databaseRoot, folderNames);
folders = folders(arrayfun(@(p) exist(p, 'dir') == 7, folders));
end

function tf = artifact_matches_current_split(existingData, trainRecordIds, testRecordIds)
tf = isfield(existingData, 'trainRecordIds') && isfield(existingData, 'testRecordIds') && ...
    isequal(sort(double(existingData.trainRecordIds(:))), sort(double(trainRecordIds(:)))) && ...
    isequal(sort(double(existingData.testRecordIds(:))), sort(double(testRecordIds(:))));
end

function [sequence_X, sequence_Y, sequence_record_ids] = make_sequence_gate_features( ...
    windowScores, windowLabels, record_ids, windowNumbers, sequenceLength, ...
    sequenceLabelMinAbnormalWindows, baseDecisionThreshold)
windowScores = double(windowScores(:));
windowLabels = double(windowLabels(:));
record_ids = double(record_ids(:));
windowNumbers = double(windowNumbers(:));

sequence_X = zeros(0, 5);
sequence_Y = zeros(0, 1);
sequence_record_ids = zeros(0, 1);
uniqueRecords = unique(record_ids(:))';

for recordId = uniqueRecords
    recordIdx = find(record_ids == recordId);
    [~, sortOrder] = sort(windowNumbers(recordIdx));
    recordIdx = recordIdx(sortOrder);
    recordWindowNumbers = windowNumbers(recordIdx);

    if numel(recordIdx) < sequenceLength
        continue;
    end

    for idx = 1:(numel(recordIdx) - sequenceLength + 1)
        candidateIdx = recordIdx(idx:(idx + sequenceLength - 1));
        candidateWindowNumbers = recordWindowNumbers(idx:(idx + sequenceLength - 1));
        if any(diff(candidateWindowNumbers) ~= 1)
            continue;
        end

        scores = windowScores(candidateIdx);
        labels = windowLabels(candidateIdx);
        abnormalVotes = scores >= baseDecisionThreshold;

        abnormalVoteCount = sum(abnormalVotes);
        maxScore = max(scores);
        sumScore = sum(scores);
        scoreDelta = scores(end) - scores(1);
        minScore = min(scores);

        sequence_X(end + 1, :) = [abnormalVoteCount, maxScore, sumScore, ...
            scoreDelta, minScore]; %#ok<AGROW>
        sequence_Y(end + 1, 1) = double(sum(labels == 1) >= sequenceLabelMinAbnormalWindows); %#ok<AGROW>
        sequence_record_ids(end + 1, 1) = recordId; %#ok<AGROW>
    end
end
end

function [targetEcg, targetLabels, targetArtifactMask] = resample_signal_labels_and_mask(ecg, sampleLabels, artifactMask, sourceFs, targetFs)
ecg = double(ecg(:));
sampleLabels = double(sampleLabels(:));
artifactMask = double(logical(artifactMask(:)));

numSamples = length(ecg);
if numSamples == 0
    targetEcg = ecg;
    targetLabels = sampleLabels;
    targetArtifactMask = logical(artifactMask);
    return;
end

sourceTime = (0:numSamples - 1)' ./ sourceFs;
targetNumSamples = max(1, floor(sourceTime(end) * targetFs) + 1);
targetTime = (0:targetNumSamples - 1)' ./ targetFs;

targetEcg = interp1(sourceTime, ecg, targetTime, 'linear', 'extrap');
targetLabels = interp1(sourceTime, sampleLabels, targetTime, 'nearest', 'extrap');
targetLabels = max(0, min(1, round(targetLabels)));
targetArtifactMask = interp1(sourceTime, artifactMask, targetTime, 'nearest', 'extrap') > 0.5;
end

function quantizedEcg = quantize_signed_q_format(ecg, integerBits, fractionBits)
ecg = double(ecg(:));
scale = 2 ^ fractionBits;
qMin = -2 ^ integerBits;
qMax = 2 ^ integerBits - 1 / scale;
quantizedEcg = fix(ecg * scale) / scale;
quantizedEcg = min(max(quantizedEcg, qMin), qMax);
end

function filteredEcg = apply_causal_pantompkins_bandpass(ecg, Fs, lowHz, highHz, filterOrder)
ecg = double(ecg(:));
if isempty(ecg)
    filteredEcg = ecg;
    return;
end

nyquistHz = Fs / 2;
if lowHz <= 0 || highHz >= nyquistHz || lowHz >= highHz
    error('Invalid Pan-Tompkins bandpass limits %.3g-%.3g Hz for Fs %.3g Hz.', ...
        lowHz, highHz, Fs);
end

[b, a] = butter(filterOrder, [lowHz highHz] / nyquistHz, 'bandpass');
ecg(~isfinite(ecg)) = 0;
filteredEcg = filter(b, a, ecg);
filteredEcg(~isfinite(filteredEcg)) = 0;
end

function [trainRows, testRows, trainRecordIds, testRecordIds] = split_records_for_holdout(Y, record_ids, testFraction, splitSeed)
Y = Y(:);
record_ids = record_ids(:);
recordValues = unique(record_ids);
numRecords = numel(recordValues);
recordHasAbnormal = false(numRecords, 1);

for recordIdx = 1:numRecords
    rows = record_ids == recordValues(recordIdx);
    recordHasAbnormal(recordIdx) = any(Y(rows) == 1);
end

rng(splitSeed);
testRecordIds = [];
for classValue = [false true]
    classRecords = recordValues(recordHasAbnormal == classValue);
    numClassRecords = numel(classRecords);
    if numClassRecords < 2
        continue;
    end

    numTestRecords = max(1, round(testFraction * numClassRecords));
    numTestRecords = min(numTestRecords, numClassRecords - 1);
    classRecords = classRecords(randperm(numClassRecords));
    testRecordIds = [testRecordIds; classRecords(1:numTestRecords)]; %#ok<AGROW>
end

if isempty(testRecordIds) && numRecords >= 2
    shuffledRecords = recordValues(randperm(numRecords));
    testRecordIds = shuffledRecords(1);
end

if isempty(testRecordIds)
    error('Record-level holdout split requires at least two records.');
end

testRecordIds = unique(testRecordIds);
testRows = ismember(record_ids, testRecordIds);
trainRows = ~testRows;
trainRecordIds = unique(record_ids(trainRows));

if ~any(trainRows) || ~any(testRows)
    error('Record-level holdout split produced an empty train or test set.');
end
end

function [X_aug, Y_aug, record_ids_aug, stats] = augment_abnormal_windows_smote(X, Y, record_ids, augmentationFactor, augmentationSeed)
X_aug = X;
Y_aug = Y;
record_ids_aug = record_ids;

abnormalIdx = find(Y == 1);
numAbnormal = numel(abnormalIdx);
numSynthetic = round(augmentationFactor * numAbnormal);

stats = struct();
stats.method = 'smote_feature_interpolation';
stats.factor = augmentationFactor;
stats.seed = augmentationSeed;
stats.numOriginalAbnormal = numAbnormal;
stats.numSynthetic = 0;

if numSynthetic <= 0 || numAbnormal < 2
    return;
end

rng(augmentationSeed);
synthetic_X = zeros(numSynthetic, size(X, 2));
synthetic_record_ids = zeros(numSynthetic, 1);

for synthIdx = 1:numSynthetic
    baseListIdx = randi(numAbnormal);
    neighborListIdx = randi(numAbnormal - 1);
    if neighborListIdx >= baseListIdx
        neighborListIdx = neighborListIdx + 1;
    end

    baseIdx = abnormalIdx(baseListIdx);
    neighborIdx = abnormalIdx(neighborListIdx);
    interpolationWeight = rand();
    synthetic_X(synthIdx, :) = X(baseIdx, :) + ...
        interpolationWeight * (X(neighborIdx, :) - X(baseIdx, :));
    synthetic_record_ids(synthIdx) = record_ids(baseIdx);
end

X_aug = [X; synthetic_X];
Y_aug = [Y; ones(numSynthetic, 1)];
record_ids_aug = [record_ids; synthetic_record_ids];
stats.numSynthetic = numSynthetic;
end

function tf = can_use_gpu_arrays()
tf = false;

try
    tf = gpuDeviceCount > 0;
    if tf
        gpuDevice;
    end
catch
    tf = false;
end
end

function [model, usedGPU, failureMessage] = fit_svm_optional_gpu(X_train, y_train, class_weights, boxConstraint, svmKernel, kernelScale, useGPU)
usedGPU = false;
failureMessage = '';

if exist('fitcsvm', 'file') ~= 2
    model = fit_linear_svm_fallback(X_train, y_train, class_weights, boxConstraint);
    return;
end

if useGPU && strcmpi(svmKernel, 'linear')
    try
        model = fitcsvm(gpuArray(single(X_train)), gpuArray(single(y_train)), ...
            'KernelFunction', svmKernel, ...
            'ClassNames', single([0, 1]), ...
            'BoxConstraint', boxConstraint, ...
            'Standardize', true, ...
            'Weights', gpuArray(single(class_weights)));
        usedGPU = true;
        return;
    catch ME
        failureMessage = ME.message;
        error('GPU fitcsvm failed and CPU fallback is disabled because useGPURequested=true. Reason: %s', ...
            failureMessage);
    end
end

model = fitcsvm(X_train, y_train, ...
    'KernelFunction', svmKernel, ...
    'ClassNames', [0, 1], ...
    'BoxConstraint', boxConstraint, ...
    'KernelScale', kernelScale, ...
    'Standardize', true, ...
    'Weights', class_weights);
end

function scores = predict_scores_optional_gpu(model, X, useGPU)
if isstruct(model) && isfield(model, 'modelType') && strcmp(model.modelType, 'linear_svm_fallback')
    decisionScores = predict_linear_svm_fallback(model, X);
    scores = [-decisionScores, decisionScores];
    return;
end

if useGPU
    try
        batchSize = 1024;
        numRows = size(X, 1);
        scores = zeros(numRows, 2);
        for startIdx = 1:batchSize:numRows
            endIdx = min(numRows, startIdx + batchSize - 1);
            [~, scoresGpu] = predict(model, gpuArray(single(X(startIdx:endIdx, :))));
            scores(startIdx:endIdx, :) = gather(scoresGpu);
        end
        return;
    catch ME
        error('GPU prediction failed and CPU fallback is disabled because useGPURequested=true. Reason: %s', ...
            ME.message);
    end
end

[~, scores] = predict(model, X);
end

function model = fit_linear_svm_fallback(X_train, y_train, class_weights, boxConstraint)
X_train = double(X_train);
y_train = double(y_train(:));
class_weights = double(class_weights(:));
y_signed = 2 * y_train - 1;

mu = mean(X_train, 1, 'omitnan');
sigma = std(X_train, 0, 1, 'omitnan');
sigma(~isfinite(sigma) | sigma <= eps) = 1;
Xz = (X_train - mu) ./ sigma;
Xz(~isfinite(Xz)) = 0;

[numRows, numFeatures] = size(Xz);
w = zeros(numFeatures, 1);
b = 0;
weightSum = max(sum(class_weights), eps);
numIterations = 300;
baseLearningRate = 0.05;

for iter = 1:numIterations
    margins = y_signed .* (Xz * w + b);
    active = margins < 1;

    if any(active)
        activeWeights = class_weights(active) .* y_signed(active);
        gradW = w - boxConstraint * (Xz(active, :)' * activeWeights) / weightSum;
        gradB = -boxConstraint * sum(activeWeights) / weightSum;
    else
        gradW = w;
        gradB = 0;
    end

    learningRate = baseLearningRate / sqrt(iter);
    w = w - learningRate * gradW;
    b = b - learningRate * gradB;

    if numRows > 0 && norm([gradW; gradB]) < 1e-6
        break;
    end
end

model = struct();
model.modelType = 'linear_svm_fallback';
model.solver = 'weighted_hinge_full_batch_gradient';
model.w = w;
model.b = b;
model.mu = mu;
model.sigma = sigma;
model.boxConstraint = boxConstraint;
model.numIterations = iter;
model.classNames = [0, 1];
end

function decisionScores = predict_linear_svm_fallback(model, X)
X = double(X);
Xz = (X - model.mu) ./ model.sigma;
Xz(~isfinite(Xz)) = 0;
decisionScores = Xz * model.w + model.b;
end

function [ecg, Fs, ann, type, comments] = read_record_with_fallback(recordname)
if exist('rdsamp', 'file') == 2 && exist('rdann', 'file') == 2
    try
        [ecg, Fs, ~] = rdsamp(recordname, 1);
        [ann, type, ~, ~, ~, comments] = rdann(recordname, 'atr', 1);
        return;
    catch ME
        warning('WFDB toolbox read failed for %s; using local format-212 reader instead. Reason: %s', ...
            recordname, ME.message);
    end
end

[ecg, Fs] = local_rdsamp_212(recordname, 1);
[ann, type, comments] = local_rdann_atr(recordname);
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

if isfinite(gain) && gain ~= 0
    signal = (adc - baseline) ./ gain;
else
    signal = adc - baseline;
end
end

function [ann, type, comments] = local_rdann_atr(recordname)
atrFile = [char(recordname), '.atr'];
fid = fopen(atrFile, 'r');
if fid < 0
    error('Could not open annotation file: %s', atrFile);
end

cleanup = onCleanup(@() fclose(fid));

ann = [];
type = char.empty(0, 1);
comments = {};
sampleIndex = 0;

while true
    pair = fread(fid, 2, 'uint8=>double');
    if length(pair) < 2
        break;
    end

    word = pair(1) + 256 * pair(2);
    annCode = floor(word / 1024);
    interval = mod(word, 1024);

    if annCode == 0 && interval == 0
        break;
    end

    if annCode == 59
        skipBytes = fread(fid, 4, 'uint8=>double');
        if length(skipBytes) < 4
            break;
        end
        skipInterval = (skipBytes(1) + 256 * skipBytes(2)) * 65536 + ...
            (skipBytes(3) + 256 * skipBytes(4));
        sampleIndex = sampleIndex + skipInterval;
        continue;
    elseif annCode == 63
        auxLength = interval;
        auxBytes = fread(fid, auxLength, 'uint8=>char')';
        if mod(auxLength, 2) == 1
            fread(fid, 1, 'uint8');
        end
        if ~isempty(comments)
            comments{end} = strtrim(char(auxBytes));
        end
        continue;
    elseif annCode >= 60 && annCode <= 62
        continue;
    end

    sampleIndex = sampleIndex + interval;
    ann(end + 1, 1) = sampleIndex;
    type(end + 1, 1) = annotation_code_to_symbol(annCode);
    comments{end + 1, 1} = '';
end
end

function symbol = annotation_code_to_symbol(annCode)
symbols = containers.Map( ...
    {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16, 18, 19, 20, ...
     21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, ...
     37, 38, 39, 40}, ...
    {'N', 'L', 'R', 'a', 'V', 'F', 'J', 'A', 'S', 'E', 'j', '/', 'Q', '~', ...
     '|', 's', 'T', '*', 'D', '"', '=', 'p', 'B', '^', 't', '+', 'u', '?', ...
     '!', '[', ']', 'e', 'n', '@', 'x', 'f', '(', ')'});

if isKey(symbols, annCode)
    symbol = symbols(annCode);
else
    symbol = '?';
end
end

function [sampleLabels, artifactMask] = build_normal_abnormal_labels(numSamples, ann, type, comments, recordBase, Fs, artifactPadSeconds)
sampleLabels = zeros(numSamples, 1);
artifactMask = false(numSamples, 1);

ann = max(1, min(numSamples, double(ann(:))));
type = type(:);

% Rhythm annotations are usually stored at '+' entries with comments such as
% '(N', '(VT', '(VF', or '(VFL'. VT and any VF-prefixed rhythm are abnormal.
changePoints = [];
changeLabels = [];
for k = 1:length(ann)
    commentText = get_annotation_comment(comments, k);
    rhythmLabel = rhythm_to_binary_label(commentText);

    if type(k) == '+'
        if is_artifact_comment(commentText)
            artifactMask = mark_annotation_interval(artifactMask, ann, k, numSamples, 0);
        elseif ~isnan(rhythmLabel)
            changePoints = [changePoints; ann(k)];
            changeLabels = [changeLabels; rhythmLabel];
        end
    elseif ismember(type(k), ['~', '|'])
        artifactMask = mark_point_with_padding(artifactMask, ann(k), Fs, artifactPadSeconds);
    end
end

for k = 1:length(ann)
    if type(k) == '+' && is_artifact_comment(get_annotation_comment(comments, k))
        artifactMask = mark_annotation_interval(artifactMask, ann, k, numSamples, round(artifactPadSeconds * Fs));
    end
end

for k = 1:length(changePoints)
    startIdx = changePoints(k);
    if k < length(changePoints)
        endIdx = changePoints(k + 1) - 1;
    else
        endIdx = numSamples;
    end

    if changeLabels(k) == 1
        sampleLabels(startIdx:endIdx) = 1;
    end
end

% CUDB uses VFON/VFOFF markers and notes that VF onset is only approximate.
% Extend the abnormal label back to sustained tachycardia preceding VFON.
if startsWith(recordBase, 'cu')
    openStart = [];
    for k = 1:length(ann)
        if type(k) == '['
            openStart = ann(k);
        elseif type(k) == ']' && ~isempty(openStart)
            sampleLabels(openStart:ann(k)) = 1;
            openStart = [];
        end
    end

    if ~isempty(openStart)
        sampleLabels(openStart:end) = 1;
    end

    sampleLabels = mark_cudb_tachycardia_lead_in(sampleLabels, ann, type, Fs, numSamples);
end

% Some databases place VT/VF text directly on non-'+' annotations. Mark from
% that annotation to the next annotation to preserve those explicit labels.
for k = 1:length(ann)
    rhythmLabel = rhythm_to_binary_label(get_annotation_comment(comments, k));
    if rhythmLabel == 1
        startIdx = ann(k);
        if k < length(ann)
            endIdx = ann(k + 1) - 1;
        else
            endIdx = numSamples;
        end
        sampleLabels(startIdx:endIdx) = 1;
    end
end
end

function artifactMask = mark_annotation_interval(artifactMask, ann, idx, numSamples, padSamples)
startIdx = max(1, ann(idx) - padSamples);
if idx < length(ann)
    endIdx = min(numSamples, ann(idx + 1) - 1 + padSamples);
else
    endIdx = numSamples;
end
artifactMask(startIdx:endIdx) = true;
end

function artifactMask = mark_point_with_padding(artifactMask, pointIdx, Fs, artifactPadSeconds)
padSamples = round(artifactPadSeconds * Fs);
startIdx = max(1, pointIdx - padSamples);
endIdx = min(length(artifactMask), pointIdx + padSamples);
artifactMask(startIdx:endIdx) = true;
end

function sampleLabels = mark_cudb_tachycardia_lead_in(sampleLabels, ann, type, Fs, numSamples)
vfStarts = ann(type == '[');
if isempty(vfStarts)
    return;
end

tachyLeadMaxSeconds = 120;
tachyRRSeconds = 0.65;
tachyMinRunBeats = 8;
tachyFastFraction = 0.75;
qrsTypes = ['N', 'L', 'R', 'a', 'V', 'F', 'J', 'A', 'S', 'E', 'j', '/', 'Q', 'e', 'n'];
qrsAnn = ann(ismember(type, qrsTypes));

for vfIdx = 1:length(vfStarts)
    vfStart = vfStarts(vfIdx);
    leadStartLimit = max(1, vfStart - round(tachyLeadMaxSeconds * Fs));
    leadBeats = qrsAnn(qrsAnn >= leadStartLimit & qrsAnn < vfStart);

    if numel(leadBeats) < tachyMinRunBeats + 1
        continue;
    end

    rrSeconds = diff(leadBeats) ./ Fs;
    fastBeat = rrSeconds <= tachyRRSeconds;
    fastDensity = movmean(double(fastBeat), [tachyMinRunBeats - 1, 0]) >= tachyFastFraction;

    if any(fastDensity)
        runStart = find(fastDensity, 1, 'first');
        tachyStart = max(1, leadBeats(max(1, runStart)));
        sampleLabels(tachyStart:min(numSamples, vfStart - 1)) = 1;
    end
end
end

function tf = is_artifact_comment(commentText)
commentText = upper(strtrim(char(commentText)));
tf = contains(commentText, 'NOISE') || contains(commentText, 'ARTIFACT') || ...
    contains(commentText, 'ARFCT') || contains(commentText, 'DEFIB') || ...
    contains(commentText, 'SHOCK');
end

function tf = is_defibrillation_record(comments)
tf = false;

if isempty(comments)
    return;
end

if iscell(comments) || isstring(comments)
    for idx = 1:numel(comments)
        if iscell(comments)
            commentText = comments{idx};
        else
            commentText = comments(idx);
        end
        commentText = upper(strtrim(char(commentText)));
        if contains(commentText, 'DEFIB') || contains(commentText, 'SHOCK')
            tf = true;
            return;
        end
    end
elseif ischar(comments)
    commentText = upper(comments);
    tf = contains(commentText, 'DEFIB') || contains(commentText, 'SHOCK');
end
end

function artifactMask = detect_signal_artifacts(ecg, Fs, artifactPadSeconds)
ecg = double(ecg(:));
artifactMask = false(size(ecg));

finiteEcg = ecg(isfinite(ecg));
if numel(finiteEcg) < 3
    return;
end

centerValue = median(finiteEcg, 'omitnan');
amplitudeScale = robust_scale(finiteEcg);
if amplitudeScale <= 0
    return;
end

centered = ecg - centerValue;
absCentered = abs(centered);
upperAmplitude = prctile(absCentered, 99.9);
typicalAmplitude = prctile(absCentered, 75);
amplitudeThreshold = max([upperAmplitude, 18 * amplitudeScale, 12 * typicalAmplitude]);
amplitudeOutlier = absCentered > amplitudeThreshold;

diffSignal = [0; diff(centered)];
diffScale = robust_scale(diffSignal(isfinite(diffSignal)));
slopeOutlier = false(size(ecg));
if diffScale > 0
    absDiffSignal = abs(diffSignal);
    diffThreshold = max([prctile(absDiffSignal, 99.95), 35 * diffScale]);
    slopeOutlier = absDiffSignal > diffThreshold & absCentered > 6 * typicalAmplitude;
end

artifactMask = amplitudeOutlier | slopeOutlier;
artifactMask = dilate_logical_mask(artifactMask, round(artifactPadSeconds * Fs));
end

function mask = dilate_logical_mask(mask, padSamples)
mask = logical(mask(:));
if padSamples <= 0 || ~any(mask)
    return;
end

kernel = ones(2 * padSamples + 1, 1);
mask = conv(double(mask), kernel, 'same') > 0;
end

function scaleValue = robust_scale(x)
x = x(:);
x = x(isfinite(x));
if isempty(x)
    scaleValue = 0;
    return;
end

medianValue = median(x, 'omitnan');
scaleValue = 1.4826 * median(abs(x - medianValue), 'omitnan');
if ~isfinite(scaleValue) || scaleValue <= eps
    scaleValue = std(x, 'omitnan');
end
if ~isfinite(scaleValue)
    scaleValue = 0;
end
end

function [X_file, Y_file, W_file] = extract_window_features(ecg, sampleLabels, Fs, windowSeconds, stepSeconds, minClassFraction, thresholdFraction, artifactMask, artifactMaxWindowFraction, quantizationIntegerBits, quantizationFractionBits)
ecg = ecg(:);
sampleLabels = sampleLabels(:);
artifactMask = logical(artifactMask(:));

windowLength = max(1, round(windowSeconds * Fs));
stepLength = max(1, round(stepSeconds * Fs));

if length(ecg) < windowLength
    X_file = [];
    Y_file = [];
    W_file = [];
    return;
end

numWindows = floor((length(ecg) - windowLength) / stepLength) + 1;
X_file = zeros(numWindows, 6);
Y_file = zeros(numWindows, 1);
W_file = zeros(numWindows, 1);
keep = false(numWindows, 1);

for w = 1:numWindows
    startIdx = (w - 1) * stepLength + 1;
    endIdx = startIdx + windowLength - 1;

    windowArtifact = artifactMask(startIdx:endIdx);
    if mean(windowArtifact) > artifactMaxWindowFraction
        continue;
    end

    windowSignal = ecg(startIdx:endIdx);
    windowLabels = sampleLabels(startIdx:endIdx);
    abnormalFraction = mean(windowLabels == 1);

    if abnormalFraction >= minClassFraction
        windowLabel = 1;
    elseif abnormalFraction <= (1 - minClassFraction)
        windowLabel = 0;
    else
        continue;
    end

    windowMean = quantize_signed_q_format(sum(windowSignal, 'omitnan') / windowLength, ...
        quantizationIntegerBits, quantizationFractionBits);
    windowSignal = windowSignal - windowMean;
    diffSignal = diff(windowSignal);

    meanAbs = quantize_signed_q_format(sum(abs(windowSignal), 'omitnan') / windowLength, ...
        quantizationIntegerBits, quantizationFractionBits);
    zeroCrossings = count_zero_crossings(diffSignal) / windowSeconds;
    lineLength = sum(abs(diffSignal), 'omitnan') / windowSeconds;
    thresholdCrossingCount = count_threshold_crossings(windowSignal, thresholdFraction);
    rmsAmplitude = sqrt(mean(windowSignal .^ 2, 'omitnan'));
    robustRange = prctile(windowSignal, 95) - prctile(windowSignal, 5);

    X_file(w, :) = [meanAbs, zeroCrossings, lineLength, thresholdCrossingCount, ...
        rmsAmplitude, robustRange];
    Y_file(w) = windowLabel;
    W_file(w) = w;
    keep(w) = true;
end

X_file = X_file(keep, :);
Y_file = Y_file(keep);
W_file = W_file(keep);
end

function [X_clean, Y_clean, record_ids_clean, keep] = remove_feature_outliers(X, Y, record_ids, zLimit)
keep = true(size(Y));
classes = unique(Y(:))';

for classValue = classes
    classIdx = find(Y == classValue);
    if numel(classIdx) < 5
        continue;
    end

    classX = X(classIdx, :);
    centerValue = median(classX, 1, 'omitnan');
    scaleValue = 1.4826 * median(abs(classX - centerValue), 1, 'omitnan');
    fallbackScale = std(classX, 0, 1, 'omitnan');
    badScale = ~isfinite(scaleValue) | scaleValue <= eps;
    scaleValue(badScale) = fallbackScale(badScale);
    scaleValue(~isfinite(scaleValue) | scaleValue <= eps) = 1;

    robustZ = abs((classX - centerValue) ./ scaleValue);
    keep(classIdx) = all(robustZ <= zLimit, 2);
end

X_clean = X(keep, :);
Y_clean = Y(keep);
record_ids_clean = record_ids(keep);
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

function commentText = get_annotation_comment(comments, idx)
commentText = '';

if isempty(comments) || idx > numel(comments)
    return;
end

if iscell(comments)
    value = comments{idx};
elseif isstring(comments)
    value = comments(idx);
elseif ischar(comments)
    if size(comments, 1) >= idx
        value = comments(idx, :);
    else
        value = comments;
    end
else
    value = '';
end

if isempty(value)
    return;
end

commentText = upper(strtrim(char(value)));
end

function label = rhythm_to_binary_label(commentText)
label = NaN;

if isempty(commentText)
    return;
end

commentText = upper(strtrim(char(commentText)));

if contains(commentText, '(VT') || contains(commentText, '(VF') || ...
        strcmp(commentText, 'VT') || startsWith(commentText, 'VF')
    label = 1;
elseif startsWith(commentText, '(')
    label = 0;
end
end

function weights = make_class_weights(y, classWeightMode)
weights = ones(size(y));
if strcmpi(classWeightMode, 'none')
    return;
end

numNormal = sum(y == 0);
numAbnormal = sum(y == 1);
total = length(y);

weights(y == 0) = total / (2 * max(numNormal, 1));
weights(y == 1) = total / (2 * max(numAbnormal, 1));
end

function [X_bal, Y_bal, record_ids_bal, skipped_X, skipped_Y, skipped_record_ids] = balance_binary_windows(X, Y, record_ids, normalToAbnormalRatio)
normalIdx = find(Y == 0);
abnormalIdx = find(Y == 1);
skipped_X = zeros(0, size(X, 2));
skipped_Y = zeros(0, 1);
skipped_record_ids = zeros(0, 1);

if isempty(normalIdx) || isempty(abnormalIdx)
    X_bal = X;
    Y_bal = Y;
    record_ids_bal = record_ids;
    return;
end

maxNormal = round(normalToAbnormalRatio * length(abnormalIdx));
if length(normalIdx) > maxNormal
    normalOrder = randperm(length(normalIdx));
    skippedNormalIdx = normalIdx(normalOrder(maxNormal + 1:end));
    normalIdx = normalIdx(normalOrder(1:maxNormal));
    skipped_X = X(skippedNormalIdx, :);
    skipped_Y = Y(skippedNormalIdx);
    skipped_record_ids = record_ids(skippedNormalIdx);
end

keepIdx = [abnormalIdx; normalIdx];
keepIdx = keepIdx(randperm(length(keepIdx)));

X_bal = X(keepIdx, :);
Y_bal = Y(keepIdx);
record_ids_bal = record_ids(keepIdx);
end

function [tuningResults, bestConfig] = tune_linear_svm_hyperparameters(X, Y, record_ids, ratioCandidates, boxCandidates, numFolds, svmKernel, kernelScale, useGPUTraining, thresholdObjectiveCandidates, minRecallForAccuracy, classWeightModeCandidates)
tuningResults = struct('normalToAbnormalRatio', {}, 'boxConstraint', {}, ...
    'thresholdObjective', {}, 'classWeightMode', {}, 'balanceSeed', {}, ...
    'numWindows', {}, 'numAbnormal', {}, 'numNormal', {}, ...
    'mean_accuracy', {}, 'mean_precision', {}, 'mean_recall', {}, ...
    'mean_f1_score', {}, 'mean_auc', {}, 'mean_threshold', {}, ...
    'selection_score', {});

fprintf('\nHyperparameter search with fixed feature set and %s SVM:\n', svmKernel);
fprintf('Selection objective: maximize CV accuracy with recall >= %.2f when possible.\n', ...
    minRecallForAccuracy);

bestIdx = 0;
bestScore = -Inf;

for ratioIdx = 1:length(ratioCandidates)
    ratioValue = ratioCandidates(ratioIdx);
    balanceSeed = 1000 + ratioIdx;
    rng(balanceSeed);
    [X_bal, Y_bal] = balance_binary_windows(X, Y, record_ids, ratioValue);

    if numel(unique(Y_bal)) < 2
        warning('Skipping ratio %.2f because it does not contain both classes.', ratioValue);
        continue;
    end

    candidateFolds = min(numFolds, min(sum(Y_bal == 0), sum(Y_bal == 1)));
    if candidateFolds < 2
        warning('Skipping ratio %.2f because it does not have enough samples per class.', ratioValue);
        continue;
    end

    for boxIdx = 1:length(boxCandidates)
        boxValue = boxCandidates(boxIdx);
        for weightIdx = 1:length(classWeightModeCandidates)
            classWeightMode = classWeightModeCandidates{weightIdx};
            for thresholdIdx = 1:length(thresholdObjectiveCandidates)
                thresholdObjective = thresholdObjectiveCandidates{thresholdIdx};
                cvResults = cross_validate_linear_svm(X_bal, Y_bal, candidateFolds, boxValue, ...
                    svmKernel, kernelScale, useGPUTraining, thresholdObjective, ...
                    minRecallForAccuracy, classWeightMode, false);

                resultIdx = length(tuningResults) + 1;
                tuningResults(resultIdx).normalToAbnormalRatio = ratioValue;
                tuningResults(resultIdx).boxConstraint = boxValue;
                tuningResults(resultIdx).thresholdObjective = thresholdObjective;
                tuningResults(resultIdx).classWeightMode = classWeightMode;
                tuningResults(resultIdx).balanceSeed = balanceSeed;
                tuningResults(resultIdx).numWindows = length(Y_bal);
                tuningResults(resultIdx).numAbnormal = sum(Y_bal == 1);
                tuningResults(resultIdx).numNormal = sum(Y_bal == 0);
                tuningResults(resultIdx).mean_accuracy = cvResults.mean_accuracy;
                tuningResults(resultIdx).mean_precision = cvResults.mean_precision;
                tuningResults(resultIdx).mean_recall = cvResults.mean_recall;
                tuningResults(resultIdx).mean_f1_score = cvResults.mean_f1_score;
                tuningResults(resultIdx).mean_auc = cvResults.mean_auc;
                tuningResults(resultIdx).mean_threshold = cvResults.mean_threshold;

                recallShortfall = max(0, minRecallForAccuracy - cvResults.mean_recall);
                tuningResults(resultIdx).selection_score = cvResults.mean_accuracy - recallShortfall;

                fprintf('  ratio %.2f | C %.3g | weights %s | threshold %s | n %d | acc %.2f%% | recall %.4f | f1 %.4f | auc %.4f\n', ...
                    ratioValue, boxValue, classWeightMode, thresholdObjective, length(Y_bal), ...
                    cvResults.mean_accuracy * 100, cvResults.mean_recall, ...
                    cvResults.mean_f1_score, cvResults.mean_auc);

                if is_better_tuning_result(tuningResults(resultIdx), bestScore, tuningResults, bestIdx)
                    bestIdx = resultIdx;
                    bestScore = tuningResults(resultIdx).selection_score;
                end
            end
        end
    end
end

if bestIdx == 0
    error('Hyperparameter search did not produce a valid model candidate.');
end

bestConfig = tuningResults(bestIdx);
fprintf('\nSelected tuning configuration:\n');
fprintf('  normalToAbnormalRatio: %.2f\n', bestConfig.normalToAbnormalRatio);
fprintf('  BoxConstraint: %.3g\n', bestConfig.boxConstraint);
fprintf('  thresholdObjective: %s\n', bestConfig.thresholdObjective);
fprintf('  classWeightMode: %s\n', bestConfig.classWeightMode);
fprintf('  CV accuracy: %.2f%% | precision: %.4f | recall: %.4f | F1: %.4f | AUC: %.4f\n', ...
    bestConfig.mean_accuracy * 100, bestConfig.mean_precision, bestConfig.mean_recall, ...
    bestConfig.mean_f1_score, bestConfig.mean_auc);
end

function tf = is_better_tuning_result(candidate, bestScore, tuningResults, bestIdx)
if isempty(bestIdx) || bestIdx == 0
    tf = true;
    return;
end

if candidate.selection_score > bestScore + eps
    tf = true;
    return;
end

if abs(candidate.selection_score - bestScore) <= eps
    currentBest = tuningResults(bestIdx);
    tf = candidate.mean_f1_score > currentBest.mean_f1_score + eps || ...
        (abs(candidate.mean_f1_score - currentBest.mean_f1_score) <= eps && ...
        candidate.mean_auc > currentBest.mean_auc + eps);
else
    tf = false;
end
end

function cvResults = cross_validate_linear_svm(X, Y, numFolds, boxConstraint, svmKernel, kernelScale, useGPUTraining, thresholdObjective, minRecallForAccuracy, classWeightMode, verbose)
fold_accuracies = zeros(numFolds, 1);
fold_precisions = zeros(numFolds, 1);
fold_recalls = zeros(numFolds, 1);
fold_f1_scores = zeros(numFolds, 1);
fold_aucs = zeros(numFolds, 1);
fold_thresholds = zeros(numFolds, 1);
fold_confusion = zeros(2, 2, numFolds);

foldAssignments = stratified_kfold_assignments(Y, numFolds);

for fold = 1:numFolds
    test_idx = foldAssignments == fold;
    train_idx = ~test_idx;

    X_train = X(train_idx, :);
    y_train = Y(train_idx);
    X_test = X(test_idx, :);
    y_test = Y(test_idx);

    class_weights = make_class_weights(y_train, classWeightMode);

    [normal_abnormal_svm_model, foldUsedGPU, gpuFailureMessage] = ...
        fit_svm_optional_gpu(X_train, y_train, class_weights, boxConstraint, ...
        svmKernel, kernelScale, useGPUTraining);

    train_scores = predict_scores_optional_gpu(normal_abnormal_svm_model, X_train, foldUsedGPU);
    decisionThreshold = choose_decision_threshold(train_scores(:, 2), y_train, ...
        thresholdObjective, minRecallForAccuracy);

    test_scores = predict_scores_optional_gpu(normal_abnormal_svm_model, X_test, foldUsedGPU);
    y_pred = double(test_scores(:, 2) >= decisionThreshold);

    metrics = binary_metrics(y_test, y_pred, test_scores(:, 2));

    fold_accuracies(fold) = metrics.accuracy;
    fold_precisions(fold) = metrics.precision;
    fold_recalls(fold) = metrics.recall;
    fold_f1_scores(fold) = metrics.f1_score;
    fold_aucs(fold) = metrics.auc;
    fold_thresholds(fold) = decisionThreshold;
    fold_confusion(:, :, fold) = [metrics.TN metrics.FP; metrics.FN metrics.TP];

    if verbose
        fprintf('\nFold %d/%d\n', fold, numFolds);
        fprintf('Train: %d windows (%d abnormal, %d normal)\n', ...
            length(y_train), sum(y_train == 1), sum(y_train == 0));
        fprintf('Test:  %d windows (%d abnormal, %d normal)\n', ...
            length(y_test), sum(y_test == 1), sum(y_test == 0));
        fprintf('Threshold: %.4f\n', decisionThreshold);
        fprintf('Accuracy: %.2f%% | Precision: %.4f | Recall: %.4f | F1: %.4f | AUC: %.4f\n', ...
            metrics.accuracy * 100, metrics.precision, metrics.recall, metrics.f1_score, metrics.auc);
    end
end

cvResults.fold_accuracies = fold_accuracies;
cvResults.fold_precisions = fold_precisions;
cvResults.fold_recalls = fold_recalls;
cvResults.fold_f1_scores = fold_f1_scores;
cvResults.fold_aucs = fold_aucs;
cvResults.fold_thresholds = fold_thresholds;
cvResults.fold_confusion = fold_confusion;
cvResults.mean_accuracy = mean(fold_accuracies);
cvResults.mean_precision = mean(fold_precisions);
cvResults.mean_recall = mean(fold_recalls);
cvResults.mean_f1_score = mean(fold_f1_scores);
cvResults.mean_auc = mean(fold_aucs, 'omitnan');
cvResults.mean_threshold = mean(fold_thresholds);
end

function foldAssignments = stratified_kfold_assignments(Y, numFolds)
Y = Y(:);
foldAssignments = zeros(size(Y));
classes = unique(Y(:))';

for classValue = classes
    classIdx = find(Y == classValue);
    classIdx = classIdx(randperm(numel(classIdx)));
    for k = 1:numel(classIdx)
        foldAssignments(classIdx(k)) = mod(k - 1, numFolds) + 1;
    end
end
end

function threshold = choose_decision_threshold(scores, y, thresholdObjective, minRecallForAccuracy)
if strcmpi(thresholdObjective, 'accuracy_recall_floor')
    threshold = choose_best_accuracy_threshold(scores, y, minRecallForAccuracy);
else
    threshold = choose_best_f1_threshold(scores, y);
end
end

function threshold = choose_best_accuracy_threshold(scores, y, minRecall)
scores = scores(:);
y = y(:);

thresholds = unique(scores(isfinite(scores)));
if isempty(thresholds)
    threshold = 0;
    return;
end

if length(thresholds) > 250
    thresholds = quantile(thresholds, linspace(0, 1, 250));
    thresholds = unique(thresholds(:));
end

bestAccuracy = -Inf;
bestF1 = -Inf;
threshold = median(thresholds);

for k = 1:length(thresholds)
    yPred = double(scores >= thresholds(k));
    metrics = binary_metrics(y, yPred, scores);

    if metrics.recall < minRecall
        continue;
    end

    if metrics.accuracy > bestAccuracy + eps || ...
            (abs(metrics.accuracy - bestAccuracy) <= eps && metrics.f1_score > bestF1)
        bestAccuracy = metrics.accuracy;
        bestF1 = metrics.f1_score;
        threshold = thresholds(k);
    end
end

if bestAccuracy == -Inf
    threshold = choose_best_f1_threshold(scores, y);
end
end

function threshold = choose_best_f1_threshold(scores, y)
scores = scores(:);
y = y(:);

thresholds = unique(scores(isfinite(scores)));
if isempty(thresholds)
    threshold = 0;
    return;
end

if length(thresholds) > 250
    thresholds = quantile(thresholds, linspace(0, 1, 250));
    thresholds = unique(thresholds(:));
end

bestF1 = -Inf;
threshold = median(thresholds);

for k = 1:length(thresholds)
    yPred = double(scores >= thresholds(k));
    metrics = binary_metrics(y, yPred, scores);
    if metrics.f1_score > bestF1
        bestF1 = metrics.f1_score;
        threshold = thresholds(k);
    end
end
end

function metrics = binary_metrics(yTrue, yPred, scores)
yTrue = yTrue(:);
yPred = yPred(:);

TP = sum(yPred == 1 & yTrue == 1);
TN = sum(yPred == 0 & yTrue == 0);
FP = sum(yPred == 1 & yTrue == 0);
FN = sum(yPred == 0 & yTrue == 1);

metrics.TP = TP;
metrics.TN = TN;
metrics.FP = FP;
metrics.FN = FN;
metrics.accuracy = (TP + TN) / max(TP + TN + FP + FN, 1);
metrics.precision = TP / (TP + FP + eps);
metrics.recall = TP / (TP + FN + eps);
metrics.f1_score = 2 * metrics.precision * metrics.recall / ...
    (metrics.precision + metrics.recall + eps);

if nargin >= 3 && numel(unique(yTrue)) == 2
    metrics.auc = binary_auc(yTrue, scores);
else
    metrics.auc = NaN;
end
end

function auc = binary_auc(yTrue, scores)
yTrue = yTrue(:);
scores = scores(:);
validRows = isfinite(yTrue) & isfinite(scores);
yTrue = yTrue(validRows);
scores = scores(validRows);

numPositive = sum(yTrue == 1);
numNegative = sum(yTrue == 0);
if numPositive == 0 || numNegative == 0
    auc = NaN;
    return;
end

[sortedScores, order] = sort(scores, 'ascend');
ranks = zeros(size(scores));
idx = 1;
while idx <= numel(sortedScores)
    tieEnd = idx;
    while tieEnd < numel(sortedScores) && sortedScores(tieEnd + 1) == sortedScores(idx)
        tieEnd = tieEnd + 1;
    end
    ranks(order(idx:tieEnd)) = (idx + tieEnd) / 2;
    idx = tieEnd + 1;
end

positiveRankSum = sum(ranks(yTrue == 1));
auc = (positiveRankSum - numPositive * (numPositive + 1) / 2) / ...
    (numPositive * numNegative);
end

function combined = combine_binary_metrics(firstMetrics, secondMetrics)
combined.TP = firstMetrics.TP + secondMetrics.TP;
combined.TN = firstMetrics.TN + secondMetrics.TN;
combined.FP = firstMetrics.FP + secondMetrics.FP;
combined.FN = firstMetrics.FN + secondMetrics.FN;
combined.accuracy = (combined.TP + combined.TN) / ...
    max(combined.TP + combined.TN + combined.FP + combined.FN, 1);
combined.precision = combined.TP / (combined.TP + combined.FP + eps);
combined.recall = combined.TP / (combined.TP + combined.FN + eps);
combined.f1_score = 2 * combined.precision * combined.recall / ...
    (combined.precision + combined.recall + eps);
combined.auc = NaN;
end

function print_dataset_stats(Y)
fprintf('Total windows: %d\n', length(Y));
fprintf('Abnormal windows: %d (%.2f%%)\n', sum(Y == 1), 100 * sum(Y == 1) / length(Y));
fprintf('Normal windows: %d (%.2f%%)\n', sum(Y == 0), 100 * sum(Y == 0) / length(Y));
end
