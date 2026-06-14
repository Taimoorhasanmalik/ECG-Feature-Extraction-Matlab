%% Train Normal vs Abnormal using moving-window features
% Abnormal = VT or VF rhythm. All other rhythms are treated as Normal.
% Features:
%   1. mean_abs: mean absolute ECG amplitude inside the window
%   2. zero_crossings: zero-crossing rate of the first-difference waveform
%   3. line_length: normalized signal path length inside the window
%   4. threshold_crossing_count: adaptive threshold crossing count
%   5. rms_amplitude: root-mean-square ECG amplitude inside the window
%   6. robust_range: 95th minus 5th percentile amplitude range

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
dataFolders = fullfile(projectRoot, "Database", databaseNames);
dataFolders = dataFolders(arrayfun(@(p) exist(p, 'dir') == 7, dataFolders));
if isempty(dataFolders)
    dataFolders = fullfile(projectRoot, "databases");
end
modelFolder = fullfile(projectRoot, "models");
targetSampleRateHz = [];
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
modelStem = "stage1_normal_vs_abnormal_window_robust_lsvm";
if cleanTrainingEnabled
    modelStem = "stage1_normal_vs_abnormal_window_clean_lsvm";
end
modelStem = modelStem + sampleRateSuffix;
if isequal(sort(databaseNames), sort(["mitdb", "vfdb", "cudb"]))
    modelFile = fullfile(modelFolder, modelStem + ".mat");
else
    modelFile = fullfile(modelFolder, sprintf("%s_%s.mat", modelStem, ...
        strjoin(databaseNames, "_")));
end

windowSeconds = 2.0;
stepSeconds = 1.0;
minWindowClassFraction = 0.80;
normalToAbnormalRatio = 1.0;
normalToAbnormalRatioCandidates = [1, 2];
numFolds = 5;
boxConstraint = 1;
boxConstraintCandidates = [0.3, 1, 3];
thresholdFraction = 0.20;
artifactPadSeconds = 1.5;
artifactMaxWindowFraction = 0.01;
featureOutlierZLimit = 8.0;
svmKernel = 'linear';
kernelScale = 'auto';
useGPURequested = false;
thresholdObjective = 'accuracy_recall_floor';
thresholdObjectiveCandidates = {'f1', 'accuracy_recall_floor'};
minRecallForAccuracy = 0.90;
classWeightMode = 'balanced';
classWeightModeCandidates = {'balanced', 'none'};

allFeatureNames = {'mean_abs', 'zero_crossings', 'line_length', 'threshold_crossing_count', ...
    'rms_amplitude', 'robust_range'};
excludedFeatureNames = strings(0, 1);
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

fprintf('\nNormal vs Abnormal window trainer\n');
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
fprintf('Artifact padding: %.2f sec | Max artifact window fraction: %.3f | Feature outlier z-limit: %.2f\n', ...
    artifactPadSeconds, artifactMaxWindowFraction, featureOutlierZLimit);
fprintf('SVM kernel: %s | KernelScale: %s | BoxConstraint: %.2f\n', ...
    svmKernel, string(kernelScale), boxConstraint);
fprintf('Normal downsampling target: %.2f x actual abnormal count\n', ...
    normalToAbnormalRatio);
fprintf('Tuning ratios: %s | BoxConstraints: %s\n', ...
    mat2str(normalToAbnormalRatioCandidates), mat2str(boxConstraintCandidates));
fprintf('Threshold objective: %s | Minimum recall guard: %.2f\n', ...
    thresholdObjective, minRecallForAccuracy);
fprintf('Class weight modes: %s\n', strjoin(string(classWeightModeCandidates), ', '));
fprintf('Selected features (%d): %s\n', numel(featureNames), strjoin(string(featureNames), ', '));
if ~isempty(excludedFeatureNames)
    fprintf('Excluded features: %s\n', strjoin(excludedFeatureNames, ', '));
    fprintf('Feature-variant model output: %s\n', modelFile);
end
if cleanTrainingEnabled
    fprintf('Clean training enabled: excluding defibrillation/shock records and %d problematic records.\n', ...
        numel(problematicRecordKeys));
    fprintf('Clean model output: %s\n', modelFile);
end
useGPUTraining = useGPURequested && strcmpi(svmKernel, 'linear') && can_use_gpu_arrays();
if useGPUTraining
    fprintf('GPU training requested: available, will try gpuArray fitcsvm.\n');
else
    fprintf('GPU training unavailable or disabled for this kernel, using CPU fitcsvm.\n');
end

for fileIdx = 1:length(recordFiles)
    recordBase = recordFiles(fileIdx).name(1:end-4);
    recordname = char(fullfile(recordFiles(fileIdx).folder, recordBase));
    [~, databaseName] = fileparts(recordFiles(fileIdx).folder);
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

    [X_file, Y_file] = extract_window_features(ecg, sampleLabels, Fs, ...
        windowSeconds, stepSeconds, minWindowClassFraction, thresholdFraction, ...
        artifactMask, artifactMaxWindowFraction);

    if isempty(Y_file)
        fprintf('No clean windows extracted from %s.\n', recordBase);
        continue;
    end

    all_X = [all_X; X_file];
    all_Y = [all_Y; Y_file];
    all_record_ids = [all_record_ids; repmat(fileIdx, length(Y_file), 1)];

    fprintf('Windows: %d | Abnormal: %d | Normal: %d\n', ...
        length(Y_file), sum(Y_file == 1), sum(Y_file == 0));
end

if isempty(all_Y)
    error('No training windows were extracted. Check database paths and annotations.');
end

X = all_X;
Y = all_Y;
record_ids = all_record_ids;
X = X(:, selectedFeatureMask);

validRows = all(isfinite(X), 2) & isfinite(Y);
X = X(validRows, :);
Y = Y(validRows);
record_ids = record_ids(validRows);

numRowsBeforeOutlierRemoval = length(Y);
[X, Y, record_ids, outlierKeep] = remove_feature_outliers(X, Y, record_ids, featureOutlierZLimit);
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

[tuningResults, bestTuningConfig] = tune_linear_svm_hyperparameters( ...
    raw_X, raw_Y, raw_record_ids, normalToAbnormalRatioCandidates, ...
    boxConstraintCandidates, numFolds, svmKernel, kernelScale, useGPUTraining, ...
    thresholdObjectiveCandidates, minRecallForAccuracy, classWeightModeCandidates);

normalToAbnormalRatio = bestTuningConfig.normalToAbnormalRatio;
boxConstraint = bestTuningConfig.boxConstraint;
thresholdObjective = bestTuningConfig.thresholdObjective;
classWeightMode = bestTuningConfig.classWeightMode;
rng(bestTuningConfig.balanceSeed);
X = raw_X;
Y = raw_Y;
record_ids = raw_record_ids;

[X, Y, record_ids, skipped_X, skipped_Y, skipped_record_ids] = ...
    balance_binary_windows(X, Y, record_ids, normalToAbnormalRatio);

fprintf('\nBalanced real-window dataset:\n');
print_dataset_stats(Y);
fprintf('Skipped real windows held out for post-training test:\n');
print_dataset_stats(skipped_Y);

if numel(unique(Y)) < 2
    error('Training requires both Normal and Abnormal windows.');
end

minClassCount = min(sum(Y == 0), sum(Y == 1));
numFolds = min(numFolds, minClassCount);
if numFolds < 2
    error('Not enough samples per class for cross-validation.');
end

fprintf('\nFeature Correlations:\n');
correlation_matrix = corrcoef(X);
for i = 1:length(featureNames)
    for j = i+1:length(featureNames)
        fprintf('Correlation between %s and %s: %.4f\n', ...
            featureNames{i}, featureNames{j}, correlation_matrix(i, j));
    end
end

fold_accuracies = zeros(numFolds, 1);
fold_precisions = zeros(numFolds, 1);
fold_recalls = zeros(numFolds, 1);
fold_f1_scores = zeros(numFolds, 1);
fold_aucs = zeros(numFolds, 1);
fold_thresholds = zeros(numFolds, 1);
fold_confusion = zeros(2, 2, numFolds);

fprintf('\nStarting %d-fold cross-validation with %s SVM...\n', numFolds, svmKernel);

cvResults = cross_validate_linear_svm(X, Y, numFolds, boxConstraint, svmKernel, ...
    kernelScale, useGPUTraining, thresholdObjective, minRecallForAccuracy, ...
    classWeightMode, true);

fold_accuracies = cvResults.fold_accuracies;
fold_precisions = cvResults.fold_precisions;
fold_recalls = cvResults.fold_recalls;
fold_f1_scores = cvResults.fold_f1_scores;
fold_aucs = cvResults.fold_aucs;
fold_thresholds = cvResults.fold_thresholds;
fold_confusion = cvResults.fold_confusion;

fprintf('\nOverall Cross-Validation Results:\n');
fprintf('Mean Accuracy: %.2f%% +/- %.2f%%\n', mean(fold_accuracies) * 100, std(fold_accuracies) * 100);
fprintf('Mean Precision: %.4f +/- %.4f\n', mean(fold_precisions), std(fold_precisions));
fprintf('Mean Recall: %.4f +/- %.4f\n', mean(fold_recalls), std(fold_recalls));
fprintf('Mean F1 Score: %.4f +/- %.4f\n', mean(fold_f1_scores), std(fold_f1_scores));
fprintf('Mean AUC: %.4f +/- %.4f\n', mean(fold_aucs, 'omitnan'), std(fold_aucs, 'omitnan'));
fprintf('Mean Threshold: %.4f +/- %.4f\n', mean(fold_thresholds), std(fold_thresholds));

overallConfusion = sum(fold_confusion, 3);
fprintf('\nAggregate Confusion Matrix [TN FP; FN TP]:\n');
disp(overallConfusion);

final_weights = make_class_weights(Y, classWeightMode);
[normal_abnormal_svm_model, finalUsedGPU, gpuFailureMessage] = ...
    fit_svm_optional_gpu(X, Y, final_weights, boxConstraint, ...
    svmKernel, kernelScale, useGPUTraining);
if useGPUTraining && ~finalUsedGPU
    fprintf('Final GPU fitcsvm failed; saved CPU model. Reason: %s\n', gpuFailureMessage);
end

full_scores = predict_scores_optional_gpu(normal_abnormal_svm_model, X, finalUsedGPU);
decisionThreshold = choose_decision_threshold(full_scores(:, 2), Y, ...
    thresholdObjective, minRecallForAccuracy);
full_pred = double(full_scores(:, 2) >= decisionThreshold);
trainingMetrics = binary_metrics(Y, full_pred, full_scores(:, 2));

fprintf('\nFinal full-data model metrics using selected threshold:\n');
fprintf('Threshold: %.4f\n', decisionThreshold);
fprintf('Accuracy: %.2f%% | Precision: %.4f | Recall: %.4f | F1: %.4f | AUC: %.4f\n', ...
    trainingMetrics.accuracy * 100, trainingMetrics.precision, ...
    trainingMetrics.recall, trainingMetrics.f1_score, trainingMetrics.auc);

skippedTestMetrics = struct();
combinedRawMetrics = struct();
if ~isempty(skipped_Y)
    skipped_scores = predict_scores_optional_gpu(normal_abnormal_svm_model, skipped_X, finalUsedGPU);
    skipped_pred = double(skipped_scores(:, 2) >= decisionThreshold);
    skippedTestMetrics = binary_metrics(skipped_Y, skipped_pred, skipped_scores(:, 2));
    combinedRawMetrics = combine_binary_metrics(trainingMetrics, skippedTestMetrics);

    fprintf('\nHeld-out skipped-window test metrics using selected threshold:\n');
    fprintf('Windows: %d | Abnormal: %d | Normal: %d\n', ...
        length(skipped_Y), sum(skipped_Y == 1), sum(skipped_Y == 0));
    fprintf('Accuracy: %.2f%% | Precision: %.4f | Recall: %.4f | F1: %.4f | AUC: %.4f\n', ...
        skippedTestMetrics.accuracy * 100, skippedTestMetrics.precision, ...
        skippedTestMetrics.recall, skippedTestMetrics.f1_score, skippedTestMetrics.auc);
    fprintf('Confusion Matrix [TN FP; FN TP]:\n');
    disp([skippedTestMetrics.TN skippedTestMetrics.FP; skippedTestMetrics.FN skippedTestMetrics.TP]);
    fprintf('Combined balanced-training + skipped-normal raw-window accuracy: %.2f%%\n', ...
        combinedRawMetrics.accuracy * 100);
else
    fprintf('\nNo real windows were skipped by class balancing.\n');
    combinedRawMetrics = trainingMetrics;
end

if ~exist(modelFolder, 'dir')
    mkdir(modelFolder);
end

save(modelFile, ...
    'normal_abnormal_svm_model', ...
    'allFeatureNames', ...
    'featureNames', ...
    'excludedFeatureNames', ...
    'selectedFeatureMask', ...
    'labelNames', ...
    'targetSampleRateHz', ...
    'windowSeconds', ...
    'stepSeconds', ...
    'minWindowClassFraction', ...
    'normalToAbnormalRatio', ...
    'normalToAbnormalRatioCandidates', ...
    'boxConstraint', ...
    'boxConstraintCandidates', ...
    'thresholdFraction', ...
    'thresholdObjective', ...
    'thresholdObjectiveCandidates', ...
    'minRecallForAccuracy', ...
    'classWeightMode', ...
    'classWeightModeCandidates', ...
    'cleanTrainingEnabled', ...
    'problematicRecordKeys', ...
    'excludedRecords', ...
    'artifactPadSeconds', ...
    'artifactMaxWindowFraction', ...
    'featureOutlierZLimit', ...
    'svmKernel', ...
    'kernelScale', ...
    'useGPURequested', ...
    'finalUsedGPU', ...
    'decisionThreshold', ...
    'fold_accuracies', ...
    'fold_precisions', ...
    'fold_recalls', ...
    'fold_f1_scores', ...
    'fold_aucs', ...
    'fold_thresholds', ...
    'overallConfusion', ...
    'tuningResults', ...
    'bestTuningConfig', ...
    'skippedTestMetrics', ...
    'combinedRawMetrics', ...
    'trainingMetrics');

fprintf('\nModel saved successfully as %s\n', modelFile);

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
if useGPU
    try
        [~, scoresGpu] = predict(model, gpuArray(single(X)));
        scores = gather(scoresGpu);
        return;
    catch
        % Fall back to CPU prediction if the trained model does not accept gpuArray input.
    end
end

[~, scores] = predict(model, X);
end

function [ecg, Fs, ann, type, comments] = read_record_with_fallback(recordname)
if exist('rdsamp', 'file') == 2 && exist('rdann', 'file') == 2
    [ecg, Fs, ~] = rdsamp(recordname, 1);
    [ann, type, ~, ~, ~, comments] = rdann(recordname, 'atr', 1);
else
    [ecg, Fs] = local_rdsamp_212(recordname, 1);
    [ann, type, comments] = local_rdann_atr(recordname);
end
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

scaleValue = 1.4826 * mad(x, 1);
if ~isfinite(scaleValue) || scaleValue <= eps
    scaleValue = std(x, 'omitnan');
end
if ~isfinite(scaleValue)
    scaleValue = 0;
end
end

function [X_file, Y_file] = extract_window_features(ecg, sampleLabels, Fs, windowSeconds, stepSeconds, minClassFraction, thresholdFraction, artifactMask, artifactMaxWindowFraction)
ecg = ecg(:);
sampleLabels = sampleLabels(:);
artifactMask = logical(artifactMask(:));

ecg = ecg - median(ecg, 'omitnan');

windowLength = max(1, round(windowSeconds * Fs));
stepLength = max(1, round(stepSeconds * Fs));

if length(ecg) < windowLength
    X_file = [];
    Y_file = [];
    return;
end

numWindows = floor((length(ecg) - windowLength) / stepLength) + 1;
X_file = zeros(numWindows, 6);
Y_file = zeros(numWindows, 1);
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

    windowSignal = windowSignal - mean(windowSignal, 'omitnan');
    diffSignal = diff(windowSignal);

    meanAbs = mean(abs(windowSignal), 'omitnan');
    zeroCrossings = count_zero_crossings(diffSignal) / windowSeconds;
    lineLength = sum(abs(diffSignal), 'omitnan') / windowSeconds;
    thresholdCrossingCount = count_threshold_crossings(windowSignal, thresholdFraction);
    rmsAmplitude = sqrt(mean(windowSignal .^ 2, 'omitnan'));
    robustRange = prctile(windowSignal, 95) - prctile(windowSignal, 5);

    X_file(w, :) = [meanAbs, zeroCrossings, lineLength, thresholdCrossingCount, ...
        rmsAmplitude, robustRange];
    Y_file(w) = windowLabel;
    keep(w) = true;
end

X_file = X_file(keep, :);
Y_file = Y_file(keep);
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
    scaleValue = 1.4826 * mad(classX, 1, 1);
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
        strcmp(commentText, 'VT') || strcmp(commentText, 'VF')
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

cv = cvpartition(Y, 'KFold', numFolds, 'Stratify', true);

for fold = 1:numFolds
    train_idx = training(cv, fold);
    test_idx = test(cv, fold);

    X_train = X(train_idx, :);
    y_train = Y(train_idx);
    X_test = X(test_idx, :);
    y_test = Y(test_idx);

    class_weights = make_class_weights(y_train, classWeightMode);

    [normal_abnormal_svm_model, foldUsedGPU, gpuFailureMessage] = ...
        fit_svm_optional_gpu(X_train, y_train, class_weights, boxConstraint, ...
        svmKernel, kernelScale, useGPUTraining);
    if useGPUTraining && ~foldUsedGPU
        fprintf('GPU fitcsvm failed; continuing on CPU. Reason: %s\n', gpuFailureMessage);
        useGPUTraining = false;
    end

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
    [~, ~, ~, metrics.auc] = perfcurve(yTrue, scores, 1);
else
    metrics.auc = NaN;
end
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
