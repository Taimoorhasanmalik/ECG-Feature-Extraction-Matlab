%% Train VT vs VF vs Normal using fixed windows and Pan-Tompkins features
% Classes:
%   0. Normal: all non-VT/VF rhythm windows
%   1. VT: ventricular tachycardia rhythm
%   2. VF: ventricular fibrillation / ventricular flutter rhythm
%
% Each training row is one fixed interval window. Pan-Tompkins features from
% all beats inside the window are summarized, then the existing window-shape
% features are appended.

clear;
clc;
close all;

rng(7);

scriptDir = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptDir);
addpath(scriptDir);

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
modelFile = fullfile(modelFolder, "vt_vf_normal_window_peak_lsvm.mat");

windowSeconds = 2.0;
stepSeconds = 1.0;
minWindowClassFraction = 0.80;
thresholdFraction = 0.20;
artifactPadSeconds = 1.5;
artifactMaxWindowFraction = 0.01;
featureOutlierZLimit = 8.0;
boxConstraint = 1;
numFolds = 5;
classBalanceRatio = 1.0;
classWeightMode = 'balanced';
svmKernel = 'linear';

peakFeatureNames = {'R_peak_amplitude', 'Q_peak_amplitude', 'S_peak_amplitude', ...
    'T_peak_amplitude', 'RR_interval', 'QS_interval'};
summaryStatNames = {'mean', 'median', 'std', 'min', 'max'};
windowFeatureNames = {'mean_abs', 'zero_crossings', 'line_length', ...
    'threshold_crossing_count', 'rms_amplitude', 'robust_range'};
detectionFeatureNames = {'r_peak_count', 'no_r_peak_found'};
featureNames = build_window_feature_names(peakFeatureNames, summaryStatNames, ...
    windowFeatureNames, detectionFeatureNames);
labelNames = {'Normal', 'VT', 'VF'};
classValues = [0; 1; 2];

% Same cleaned-record list used by the cleaned Normal-vs-Abnormal trainer.
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

fprintf('\nVT vs VF vs Normal trainer\n');
fprintf('Folders:\n');
for folderIdx = 1:length(dataFolders)
    fprintf('  %s\n', dataFolders(folderIdx));
end
fprintf('Window: %.2f sec | Step: %.2f sec | Clean-label fraction: %.2f\n', ...
    windowSeconds, stepSeconds, minWindowClassFraction);
fprintf('Artifact padding: %.2f sec | Max artifact window fraction: %.3f | Feature outlier z-limit: %.2f\n', ...
    artifactPadSeconds, artifactMaxWindowFraction, featureOutlierZLimit);
fprintf('SVM: %s | BoxConstraint: %.2f | Class balance ratio: %.2f\n', ...
    svmKernel, boxConstraint, classBalanceRatio);

for fileIdx = 1:length(recordFiles)
    recordBase = recordFiles(fileIdx).name(1:end-4);
    recordname = char(fullfile(recordFiles(fileIdx).folder, recordBase));
    [~, databaseName] = fileparts(recordFiles(fileIdx).folder);
    recordKey = string(databaseName) + "/" + string(recordBase);

    if any(problematicRecordKeys == recordKey)
        fprintf('\nSkipping %s: marked as problematic by previous clean validation.\n', recordKey);
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

    if is_defibrillation_record(comments)
        fprintf('Skipping %s: annotation comments contain defibrillation/shock markers.\n', recordKey);
        excludedRecordKeys(end + 1, 1) = recordKey; %#ok<SAGROW>
        excludedRecordReasons(end + 1, 1) = "defibrillation_or_shock"; %#ok<SAGROW>
        continue;
    end

    ecg = double(ecg(:));
    [sampleLabels, annotationArtifactMask] = build_vt_vf_normal_labels( ...
        length(ecg), ann, type, comments, recordBase, Fs, artifactPadSeconds);
    signalArtifactMask = detect_signal_artifacts(ecg, Fs, artifactPadSeconds);
    artifactMask = annotationArtifactMask | signalArtifactMask;

    try
        [X_file, Y_file] = extract_fixed_window_features(ecg, sampleLabels, Fs, ...
            windowSeconds, stepSeconds, minWindowClassFraction, thresholdFraction, ...
            artifactMask, artifactMaxWindowFraction);
    catch ME
        warning('Skipping %s because window feature extraction failed: %s', recordBase, ME.message);
        continue;
    end

    if isempty(Y_file)
        fprintf('No clean fixed windows extracted from %s.\n', recordBase);
        continue;
    end

    all_X = [all_X; X_file]; %#ok<AGROW>
    all_Y = [all_Y; Y_file]; %#ok<AGROW>
    all_record_ids = [all_record_ids; repmat(fileIdx, length(Y_file), 1)]; %#ok<AGROW>

    fprintf('Fixed windows: %d | Normal: %d | VT: %d | VF: %d\n', ...
        length(Y_file), sum(Y_file == 0), sum(Y_file == 1), sum(Y_file == 2));
end

if isempty(all_Y)
    error('No training samples were extracted. Check database paths and annotations.');
end

X = all_X;
Y = all_Y;
record_ids = all_record_ids;

validRows = all(isfinite(X), 2) & isfinite(Y);
X = X(validRows, :);
Y = Y(validRows);
record_ids = record_ids(validRows);

numRowsBeforeOutlierRemoval = length(Y);
[X, Y, record_ids, outlierKeep] = remove_feature_outliers(X, Y, record_ids, featureOutlierZLimit);
fprintf('\nFeature outlier removal skipped %d/%d samples.\n', ...
    numRowsBeforeOutlierRemoval - sum(outlierKeep), numRowsBeforeOutlierRemoval);

fprintf('\nClean raw dataset:\n');
print_multiclass_stats(Y, labelNames, classValues);

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

[X, Y, record_ids, skipped_X, skipped_Y, skipped_record_ids] = ...
    balance_multiclass_samples(raw_X, raw_Y, raw_record_ids, classValues, classBalanceRatio);

fprintf('\nBalanced training dataset:\n');
print_multiclass_stats(Y, labelNames, classValues);
fprintf('\nSkipped samples held out by class balancing:\n');
print_multiclass_stats(skipped_Y, labelNames, classValues);

if numel(unique(Y)) < numel(classValues)
    error('Training requires Normal, VT, and VF samples after balancing.');
end

minClassCount = min(arrayfun(@(c) sum(Y == c), classValues));
numFolds = min(numFolds, minClassCount);
if numFolds < 2
    error('Not enough samples per class for cross-validation.');
end

fprintf('\nFeature Correlations:\n');
correlationMatrix = corrcoef(X);
for i = 1:length(featureNames)
    for j = i+1:length(featureNames)
        fprintf('Correlation between %s and %s: %.4f\n', ...
            featureNames{i}, featureNames{j}, correlationMatrix(i, j));
    end
end

fprintf('\nStarting %d-fold cross-validation with linear ECOC SVM...\n', numFolds);
cvResults = cross_validate_multiclass_svm(X, Y, classValues, labelNames, ...
    numFolds, boxConstraint, classWeightMode, true);

fprintf('\nOverall Cross-Validation Results:\n');
fprintf('Mean Accuracy: %.2f%% +/- %.2f%%\n', ...
    mean(cvResults.fold_accuracies) * 100, std(cvResults.fold_accuracies) * 100);
fprintf('Mean Macro Precision: %.4f +/- %.4f\n', ...
    mean(cvResults.fold_macro_precisions), std(cvResults.fold_macro_precisions));
fprintf('Mean Macro Recall: %.4f +/- %.4f\n', ...
    mean(cvResults.fold_macro_recalls), std(cvResults.fold_macro_recalls));
fprintf('Mean Macro F1: %.4f +/- %.4f\n', ...
    mean(cvResults.fold_macro_f1_scores), std(cvResults.fold_macro_f1_scores));
fprintf('\nAggregate Confusion Matrix rows=true, cols=predicted [%s]:\n', ...
    strjoin(labelNames, ', '));
disp(cvResults.overall_confusion);

finalWeights = make_multiclass_weights(Y, classValues, classWeightMode);
vt_vf_normal_svm_model = fit_multiclass_linear_svm(X, Y, classValues, ...
    finalWeights, boxConstraint);

finalPred = predict(vt_vf_normal_svm_model, X);
trainingMetrics = multiclass_metrics(Y, finalPred, classValues);
fprintf('\nFinal full-data model metrics:\n');
fprintf('Accuracy: %.2f%% | Macro Precision: %.4f | Macro Recall: %.4f | Macro F1: %.4f\n', ...
    trainingMetrics.accuracy * 100, trainingMetrics.macro_precision, ...
    trainingMetrics.macro_recall, trainingMetrics.macro_f1_score);
fprintf('Confusion Matrix rows=true, cols=predicted [%s]:\n', strjoin(labelNames, ', '));
disp(trainingMetrics.confusion);

skippedTestMetrics = struct();
if ~isempty(skipped_Y)
    skippedPred = predict(vt_vf_normal_svm_model, skipped_X);
    skippedTestMetrics = multiclass_metrics(skipped_Y, skippedPred, classValues);
    fprintf('\nHeld-out skipped-sample metrics using final model:\n');
    fprintf('Accuracy: %.2f%% | Macro Precision: %.4f | Macro Recall: %.4f | Macro F1: %.4f\n', ...
        skippedTestMetrics.accuracy * 100, skippedTestMetrics.macro_precision, ...
        skippedTestMetrics.macro_recall, skippedTestMetrics.macro_f1_score);
    fprintf('Confusion Matrix rows=true, cols=predicted [%s]:\n', strjoin(labelNames, ', '));
    disp(skippedTestMetrics.confusion);
else
    fprintf('\nNo samples were skipped by class balancing.\n');
end

if ~exist(modelFolder, 'dir')
    mkdir(modelFolder);
end

save(modelFile, ...
    'vt_vf_normal_svm_model', ...
    'featureNames', ...
    'labelNames', ...
    'classValues', ...
    'windowSeconds', ...
    'stepSeconds', ...
    'minWindowClassFraction', ...
    'thresholdFraction', ...
    'artifactPadSeconds', ...
    'artifactMaxWindowFraction', ...
    'featureOutlierZLimit', ...
    'classBalanceRatio', ...
    'boxConstraint', ...
    'classWeightMode', ...
    'svmKernel', ...
    'problematicRecordKeys', ...
    'excludedRecords', ...
    'raw_X', ...
    'raw_Y', ...
    'raw_record_ids', ...
    'skipped_X', ...
    'skipped_Y', ...
    'skipped_record_ids', ...
    'cvResults', ...
    'trainingMetrics', ...
    'skippedTestMetrics');

fprintf('\nModel saved successfully as %s\n', modelFile);

function [model] = fit_multiclass_linear_svm(X_train, y_train, classValues, weights, boxConstraint)
template = templateSVM( ...
    'KernelFunction', 'linear', ...
    'BoxConstraint', boxConstraint, ...
    'Standardize', true);

model = fitcecoc(X_train, y_train, ...
    'Learners', template, ...
    'Coding', 'onevsone', ...
    'ClassNames', classValues(:), ...
    'Weights', weights);
end

function cvResults = cross_validate_multiclass_svm(X, Y, classValues, labelNames, numFolds, boxConstraint, classWeightMode, verbose)
fold_accuracies = zeros(numFolds, 1);
fold_macro_precisions = zeros(numFolds, 1);
fold_macro_recalls = zeros(numFolds, 1);
fold_macro_f1_scores = zeros(numFolds, 1);
fold_confusion = zeros(length(classValues), length(classValues), numFolds);

cv = cvpartition(Y, 'KFold', numFolds, 'Stratify', true);

for fold = 1:numFolds
    trainIdx = training(cv, fold);
    testIdx = test(cv, fold);

    X_train = X(trainIdx, :);
    y_train = Y(trainIdx);
    X_test = X(testIdx, :);
    y_test = Y(testIdx);

    weights = make_multiclass_weights(y_train, classValues, classWeightMode);
    model = fit_multiclass_linear_svm(X_train, y_train, classValues, weights, boxConstraint);
    y_pred = predict(model, X_test);
    metrics = multiclass_metrics(y_test, y_pred, classValues);

    fold_accuracies(fold) = metrics.accuracy;
    fold_macro_precisions(fold) = metrics.macro_precision;
    fold_macro_recalls(fold) = metrics.macro_recall;
    fold_macro_f1_scores(fold) = metrics.macro_f1_score;
    fold_confusion(:, :, fold) = metrics.confusion;

    if verbose
        fprintf('\nFold %d/%d\n', fold, numFolds);
        fprintf('Train:\n');
        print_multiclass_stats(y_train, labelNames, classValues);
        fprintf('Test:\n');
        print_multiclass_stats(y_test, labelNames, classValues);
        fprintf('Accuracy: %.2f%% | Macro Precision: %.4f | Macro Recall: %.4f | Macro F1: %.4f\n', ...
            metrics.accuracy * 100, metrics.macro_precision, ...
            metrics.macro_recall, metrics.macro_f1_score);
        fprintf('Confusion Matrix rows=true, cols=predicted [%s]:\n', strjoin(labelNames, ', '));
        disp(metrics.confusion);
    end
end

cvResults.fold_accuracies = fold_accuracies;
cvResults.fold_macro_precisions = fold_macro_precisions;
cvResults.fold_macro_recalls = fold_macro_recalls;
cvResults.fold_macro_f1_scores = fold_macro_f1_scores;
cvResults.fold_confusion = fold_confusion;
cvResults.overall_confusion = sum(fold_confusion, 3);
end

function metrics = multiclass_metrics(yTrue, yPred, classValues)
yTrue = yTrue(:);
yPred = yPred(:);
confusion = confusionmat(yTrue, yPred, 'Order', classValues(:));

tp = diag(confusion);
fp = sum(confusion, 1)' - tp;
fn = sum(confusion, 2) - tp;

precision = tp ./ (tp + fp + eps);
recall = tp ./ (tp + fn + eps);
f1Score = 2 * precision .* recall ./ (precision + recall + eps);

metrics.confusion = confusion;
metrics.accuracy = sum(tp) / max(sum(confusion(:)), 1);
metrics.class_precision = precision;
metrics.class_recall = recall;
metrics.class_f1_score = f1Score;
metrics.macro_precision = mean(precision);
metrics.macro_recall = mean(recall);
metrics.macro_f1_score = mean(f1Score);
end

function weights = make_multiclass_weights(y, classValues, classWeightMode)
weights = ones(size(y));
if strcmpi(classWeightMode, 'none')
    return;
end

total = length(y);
numClasses = length(classValues);
for idx = 1:numClasses
    classValue = classValues(idx);
    classCount = sum(y == classValue);
    weights(y == classValue) = total / (numClasses * max(classCount, 1));
end
end

function [X_bal, Y_bal, record_ids_bal, skipped_X, skipped_Y, skipped_record_ids] = balance_multiclass_samples(X, Y, record_ids, classValues, classBalanceRatio)
classCounts = arrayfun(@(c) sum(Y == c), classValues);
if any(classCounts == 0)
    X_bal = X;
    Y_bal = Y;
    record_ids_bal = record_ids;
    skipped_X = zeros(0, size(X, 2));
    skipped_Y = zeros(0, 1);
    skipped_record_ids = zeros(0, 1);
    return;
end

targetCount = max(1, round(min(classCounts) * classBalanceRatio));
keepIdx = [];
skippedIdx = [];

for idx = 1:length(classValues)
    classIdx = find(Y == classValues(idx));
    classIdx = classIdx(randperm(length(classIdx)));
    keepCount = min(targetCount, length(classIdx));
    keepIdx = [keepIdx; classIdx(1:keepCount)]; %#ok<AGROW>
    if keepCount < length(classIdx)
        skippedIdx = [skippedIdx; classIdx(keepCount + 1:end)]; %#ok<AGROW>
    end
end

keepIdx = keepIdx(randperm(length(keepIdx)));
X_bal = X(keepIdx, :);
Y_bal = Y(keepIdx);
record_ids_bal = record_ids(keepIdx);

skipped_X = X(skippedIdx, :);
skipped_Y = Y(skippedIdx);
skipped_record_ids = record_ids(skippedIdx);
end

function featureNames = build_window_feature_names(peakFeatureNames, summaryStatNames, windowFeatureNames, detectionFeatureNames)
featureNames = {};
for featureIdx = 1:length(peakFeatureNames)
    for statIdx = 1:length(summaryStatNames)
        featureNames{end + 1} = sprintf('%s_%s', ...
            peakFeatureNames{featureIdx}, summaryStatNames{statIdx}); %#ok<AGROW>
    end
end
featureNames = [featureNames, windowFeatureNames, detectionFeatureNames];
end

function [X_file, Y_file] = extract_fixed_window_features(ecg, sampleLabels, Fs, windowSeconds, stepSeconds, minClassFraction, thresholdFraction, artifactMask, artifactMaxWindowFraction)
ecg = double(ecg(:));
sampleLabels = sampleLabels(:);
artifactMask = logical(artifactMask(:));
ecgCentered = ecg - median(ecg, 'omitnan');

[R_vals, R_idx, Q_idx, Q_vals, S_idx, S_vals, T_idx, T_vals, ~] = pan_tompkin(ecgCentered, Fs, 0);

obs = min([length(R_idx), length(R_vals), length(Q_idx), length(Q_vals), ...
    length(S_idx), length(S_vals), length(T_idx), length(T_vals)]);

R_idx = R_idx(1:obs);
R_vals = R_vals(1:obs);
Q_idx = Q_idx(1:obs);
Q_vals = Q_vals(1:obs);
S_idx = S_idx(1:obs);
S_vals = S_vals(1:obs);
T_vals = T_vals(1:obs);

if obs >= 2
    rrIntervals = [median(diff(R_idx) ./ Fs, 'omitnan'), diff(R_idx) ./ Fs];
elseif obs == 1
    rrIntervals = 0;
else
    rrIntervals = [];
end
qsIntervals = (S_idx - Q_idx) ./ Fs;

windowLength = max(1, round(windowSeconds * Fs));
stepLength = max(1, round(stepSeconds * Fs));

if length(ecgCentered) < windowLength
    X_file = [];
    Y_file = [];
    return;
end

numWindows = floor((length(ecgCentered) - windowLength) / stepLength) + 1;
X_file = zeros(numWindows, 38);
Y_file = zeros(numWindows, 1);
keep = false(numWindows, 1);

for windowIdx = 1:numWindows
    startIdx = (windowIdx - 1) * stepLength + 1;
    endIdx = startIdx + windowLength - 1;

    windowArtifact = artifactMask(startIdx:endIdx);
    if mean(windowArtifact) > artifactMaxWindowFraction
        continue;
    end

    windowLabels = sampleLabels(startIdx:endIdx);
    labelFractions = [mean(windowLabels == 0), mean(windowLabels == 1), mean(windowLabels == 2)];
    [maxFraction, maxIdx] = max(labelFractions);
    if maxFraction < minClassFraction
        continue;
    end
    windowLabel = maxIdx - 1;

    beatMask = R_idx >= startIdx & R_idx <= endIdx;
    rPeakCount = sum(beatMask);
    noRPeakFound = double(rPeakCount == 0);

    windowSignal = ecgCentered(startIdx:endIdx);
    windowSignal = windowSignal - mean(windowSignal, 'omitnan');
    diffSignal = diff(windowSignal);

    meanAbs = mean(abs(windowSignal), 'omitnan');
    zeroCrossings = count_zero_crossings(diffSignal) / windowSeconds;
    lineLength = sum(abs(diffSignal), 'omitnan') / windowSeconds;
    thresholdCrossingCount = count_threshold_crossings(windowSignal, thresholdFraction);
    rmsAmplitude = sqrt(mean(windowSignal .^ 2, 'omitnan'));
    robustRange = prctile(windowSignal, 95) - prctile(windowSignal, 5);

    if noRPeakFound
        peakFeatures = zeros(1, 30);
    else
        peakFeatures = [
            summarize_window_values(R_vals(beatMask)), ...
            summarize_window_values(Q_vals(beatMask)), ...
            summarize_window_values(S_vals(beatMask)), ...
            summarize_window_values(T_vals(beatMask)), ...
            summarize_window_values(rrIntervals(beatMask)), ...
            summarize_window_values(qsIntervals(beatMask))];
    end

    X_file(windowIdx, :) = [peakFeatures, meanAbs, zeroCrossings, lineLength, ...
        thresholdCrossingCount, rmsAmplitude, robustRange, rPeakCount, noRPeakFound];
    Y_file(windowIdx) = windowLabel;
    keep(windowIdx) = true;
end

X_file = X_file(keep, :);
Y_file = Y_file(keep);
end

function stats = summarize_window_values(values)
values = values(:);
values = values(isfinite(values));
if isempty(values)
    stats = nan(1, 5);
    return;
end

stats = [mean(values, 'omitnan'), median(values, 'omitnan'), ...
    std(values, 0, 'omitnan'), min(values), max(values)];
if isscalar(values) || ~isfinite(stats(3))
    stats(3) = 0;
end
end

function [sampleLabels, artifactMask] = build_vt_vf_normal_labels(numSamples, ann, type, comments, recordBase, Fs, artifactPadSeconds)
sampleLabels = zeros(numSamples, 1);
artifactMask = false(numSamples, 1);

ann = max(1, min(numSamples, double(ann(:))));
type = type(:);

changePoints = [];
changeLabels = [];
for k = 1:length(ann)
    commentText = get_annotation_comment(comments, k);
    rhythmLabel = rhythm_to_multiclass_label(commentText);

    if type(k) == '+'
        if is_artifact_comment(commentText)
            artifactMask = mark_annotation_interval(artifactMask, ann, k, numSamples, 0);
        elseif ~isnan(rhythmLabel)
            changePoints = [changePoints; ann(k)]; %#ok<AGROW>
            changeLabels = [changeLabels; rhythmLabel]; %#ok<AGROW>
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
    sampleLabels(startIdx:endIdx) = changeLabels(k);
end

if startsWith(recordBase, 'cu')
    openStart = [];
    for k = 1:length(ann)
        if type(k) == '['
            openStart = ann(k);
        elseif type(k) == ']' && ~isempty(openStart)
            sampleLabels(openStart:ann(k)) = 2;
            openStart = [];
        end
    end

    if ~isempty(openStart)
        sampleLabels(openStart:end) = 2;
    end

    sampleLabels = mark_cudb_tachycardia_lead_in_as_vt(sampleLabels, ann, type, Fs, numSamples);
end

for k = 1:length(ann)
    rhythmLabel = rhythm_to_multiclass_label(get_annotation_comment(comments, k));
    if rhythmLabel == 1 || rhythmLabel == 2
        startIdx = ann(k);
        if k < length(ann)
            endIdx = ann(k + 1) - 1;
        else
            endIdx = numSamples;
        end
        sampleLabels(startIdx:endIdx) = rhythmLabel;
    end
end
end

function sampleLabels = mark_cudb_tachycardia_lead_in_as_vt(sampleLabels, ann, type, Fs, numSamples)
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

function label = rhythm_to_multiclass_label(commentText)
label = NaN;

if isempty(commentText)
    return;
end

commentText = upper(strtrim(char(commentText)));

if contains(commentText, '(VF') || contains(commentText, '(VFL') || ...
        strcmp(commentText, 'VF') || strcmp(commentText, 'VFL')
    label = 2;
elseif contains(commentText, '(VT') || strcmp(commentText, 'VT')
    label = 1;
elseif startsWith(commentText, '(')
    label = 0;
end
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
    ann(end + 1, 1) = sampleIndex; %#ok<AGROW>
    type(end + 1, 1) = annotation_code_to_symbol(annCode); %#ok<AGROW>
    comments{end + 1, 1} = ''; %#ok<AGROW>
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

function print_multiclass_stats(Y, labelNames, classValues)
fprintf('Total samples: %d\n', length(Y));
if isempty(Y)
    for idx = 1:length(classValues)
        fprintf('%s samples: 0 (0.00%%)\n', labelNames{idx});
    end
    return;
end

for idx = 1:length(classValues)
    count = sum(Y == classValues(idx));
    fprintf('%s samples: %d (%.2f%%)\n', ...
        labelNames{idx}, count, 100 * count / length(Y));
end
end
