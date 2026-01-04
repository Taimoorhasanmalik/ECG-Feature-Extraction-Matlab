%% Train Stage-1 Low-Power Gate (Window Features + LSVM)
% Trains a lightweight Normal-vs-Abnormal window classifier using the same
% features computed by `stage1_low_power_gate`.
%
% Labels (per window, from beat annotations):
%   - Normal (0): abnormal beat fraction < minAbnormalFraction
%   - Abnormal (1): abnormal beat fraction >= minAbnormalFraction
% Windows with < minBeatsPerWindow beats are skipped.
%
% Model:
%   - Linear SVM (LSVM) with cost-sensitive training to reduce false negatives.
%   - Decision threshold tuned on training split to hit targetRecall (minimum),
%     selecting the threshold that maximizes accuracy among those.

rng(0);

scriptDir = fileparts(mfilename('fullpath'));
repoRoot = fileparts(scriptDir);
addpath(scriptDir);
origDir = pwd;
cd(repoRoot);
cleanupObj = onCleanup(@() cd(origDir));


recordDirs = ["Database/mitdb"];
recordDirs = recordDirs(isfolder(recordDirs));

records = {};
for d = 1:numel(recordDirs)
    heaFiles = dir(fullfile(recordDirs(d), '*.hea'));
    for k = 1:numel(heaFiles)
        records{end+1, 1} = fullfile(recordDirs(d), heaFiles(k).name(1:end-4)); %#ok<SAGROW>
    end
end

fprintf('Stage-1 gate training: found %d records across %d folders.\n', numel(records), numel(recordDirs));

% -------- Gate feature parameters (Tier A) --------
gateOpts = struct();
gateOpts.targetFs = 125;
gateOpts.windowSec = 2;
gateOpts.hopSec = 1;
gateOpts.dcCutoffHz = 0.5;
gateOpts.qrsHpHz = 5;
gateOpts.qrsLpHz = 15;

% -------- Window label parameters --------
minBeatsPerWindow = 3;
minAbnormalFraction = 0.25;

% -------- Training objectives --------
num_folds = 5;
targetRecall = 0.90; % minimum recall (abnormal=1) on TRAIN split
fnCost = 3;          % penalize missing abnormal (1->0)
cost = [0 1; fnCost 0]; % row=true class, col=pred class (ClassNames=[0 1])

X_all = [];
Y_all = [];
featureNames = {};

for recIdx = 1:numel(records)
    recordname = char(records{recIdx});
    fprintf('Reading: %s\n', recordname);

    try
        [ecg, Fs] = rdsamp(recordname, 1);
        [ann, type] = rdann(recordname, 'atr', 1);
    catch ME
        warning('Skipping %s: %s', recordname, ME.message);
        continue;
    end

    if isempty(ecg) || isempty(ann) || isempty(type)
        continue;
    end

    g = stage1_low_power_gate(ecg(:), Fs, gateOpts);
    if isempty(featureNames)
        featureNames = g.featureNames;
    end

    y_win = local_window_labels_from_beats(ann, type, g.windowStartSample, g.windowEndSample, ...
        minBeatsPerWindow, minAbnormalFraction);
    keep = ~isnan(y_win);
    if ~any(keep)
        continue;
    end

    X_all = [X_all; g.features(keep, :)]; %#ok<AGROW>
    Y_all = [Y_all; y_win(keep)]; %#ok<AGROW>
end

fprintf('\nStage-1 Gate Dataset:\n');
fprintf('Total windows: %d\n', numel(Y_all));
fprintf('Normal windows: %d (%.2f%%)\n', sum(Y_all == 0), 100 * sum(Y_all == 0) / max(1, numel(Y_all)));
fprintf('Abnormal windows: %d (%.2f%%)\n', sum(Y_all == 1), 100 * sum(Y_all == 1) / max(1, numel(Y_all)));
fprintf('Unique labels present: %s\n', mat2str(unique(Y_all)'));

if isempty(X_all) || numel(unique(Y_all)) < 2
    error('Stage-1 gate training: need at least 2 classes (Normal and Abnormal).');
end

% Quick single-feature screening vs label (helps pick a single gate feature)
fprintf('\nSingle-feature screening (vs window label):\n');
for k = 1:numel(featureNames)
    x = X_all(:, k);
    r = corr(x, Y_all, 'Rows', 'complete');
    [~, ~, ~, auc] = perfcurve(Y_all, x, 1);
    fprintf('%s: corr=%.4f, AUC=%.4f\n', featureNames{k}, r, auc);
end

% Cross-validation
cv = cvpartition(Y_all, 'KFold', num_folds, 'Stratify', true);
fold_accuracies = zeros(num_folds, 1);
fold_precisions = zeros(num_folds, 1);
fold_recalls = zeros(num_folds, 1);
fold_f1_scores = zeros(num_folds, 1);
fold_aucs = zeros(num_folds, 1);
fold_thresholds = zeros(num_folds, 1);
fold_train_recalls = zeros(num_folds, 1);

fprintf('\nStage-1 %d-fold cross-validation (LSVM, low-power features)...\n', num_folds);
for fold = 1:num_folds
    train_idx = training(cv, fold);
    test_idx = test(cv, fold);

    X_train = X_all(train_idx, :);
    y_train = Y_all(train_idx);
    X_test = X_all(test_idx, :);
    y_test = Y_all(test_idx);

    n_ab = sum(y_train == 1);
    n_n = sum(y_train == 0);
    w = ones(size(y_train));
    if n_ab > 0 && n_n > 0
        w(y_train == 1) = n_n / n_ab;
        w(y_train == 0) = 1;
    end

    stage1_svm = fitcsvm(X_train, y_train, ...
        'KernelFunction', 'linear', ...
        'ClassNames', [0, 1], ...
        'Standardize', true, ...
        'Weights', w, ...
        'Cost', cost);

    [~, scores_train] = predict(stage1_svm, X_train);
    fold_threshold = local_threshold_for_min_recall(y_train, scores_train(:, 2), targetRecall);
    fold_thresholds(fold) = fold_threshold;

    y_pred_train = scores_train(:, 2) > fold_threshold;
    TP_tr = sum(y_pred_train == 1 & y_train == 1);
    FN_tr = sum(y_pred_train == 0 & y_train == 1);
    fold_train_recalls(fold) = TP_tr / (TP_tr + FN_tr + eps);

    [~, scores] = predict(stage1_svm, X_test);
    y_pred = scores(:, 2) > fold_threshold;

    TP = sum(y_pred == 1 & y_test == 1);
    TN = sum(y_pred == 0 & y_test == 0);
    FP = sum(y_pred == 1 & y_test == 0);
    FN = sum(y_pred == 0 & y_test == 1);

    accuracy = (TP + TN) / max(1, (TP + TN + FP + FN));
    precision = TP / (TP + FP + eps);
    recall = TP / (TP + FN + eps);
    f1_score = 2 * (precision * recall) / (precision + recall + eps);

    [~, ~, ~, AUC] = perfcurve(y_test, scores(:, 2), 1);

    fold_accuracies(fold) = accuracy;
    fold_precisions(fold) = precision;
    fold_recalls(fold) = recall;
    fold_f1_scores(fold) = f1_score;
    fold_aucs(fold) = AUC;

    fprintf('Fold %d/%d | Thr %.3f | TrainRec %.3f | Acc %.2f%% | Prec %.3f | Rec %.3f | F1 %.3f | AUC %.3f\n', ...
        fold, num_folds, fold_threshold, fold_train_recalls(fold), accuracy * 100, precision, recall, f1_score, AUC);
end

fprintf('\nStage-1 Overall:\n');
fprintf('Mean Accuracy: %.2f%% ± %.2f%%\n', mean(fold_accuracies) * 100, std(fold_accuracies) * 100);
fprintf('Mean Precision: %.4f ± %.4f\n', mean(fold_precisions, 'omitnan'), std(fold_precisions, 'omitnan'));
fprintf('Mean Recall: %.4f ± %.4f\n', mean(fold_recalls, 'omitnan'), std(fold_recalls, 'omitnan'));
fprintf('Mean F1: %.4f ± %.4f\n', mean(fold_f1_scores, 'omitnan'), std(fold_f1_scores, 'omitnan'));
fprintf('Mean AUC: %.4f ± %.4f\n', mean(fold_aucs, 'omitnan'), std(fold_aucs, 'omitnan'));
fprintf('Mean tuned threshold: %.4f ± %.4f (targetRecall=%.2f, fnCost=%g)\n', ...
    mean(fold_thresholds), std(fold_thresholds), targetRecall, fnCost);

% Train final model and tune a global threshold on all data
n_ab = sum(Y_all == 1);
n_n = sum(Y_all == 0);
w_all = ones(size(Y_all));
if n_ab > 0 && n_n > 0
    w_all(Y_all == 1) = n_n / n_ab;
    w_all(Y_all == 0) = 1;
end

stage1_svm_model = fitcsvm(X_all, Y_all, ...
    'KernelFunction', 'linear', ...
    'ClassNames', [0, 1], ...
    'Standardize', true, ...
    'Weights', w_all, ...
    'Cost', cost);

[~, scores_all] = predict(stage1_svm_model, X_all);
abnormal_threshold = local_threshold_for_min_recall(Y_all, scores_all(:, 2), targetRecall);

modelsDir = fullfile(repoRoot, 'models');
if ~isfolder(modelsDir)
    mkdir(modelsDir);
end

modelPath = fullfile(modelsDir, 'stage1_low_power_gate_lsvm.mat');
save(modelPath, ...
    'stage1_svm_model', 'featureNames', 'recordDirs', 'gateOpts', ...
    'minBeatsPerWindow', 'minAbnormalFraction', ...
    'abnormal_threshold', 'targetRecall', 'fnCost', 'cost');

fprintf('\nSaved stage-1 gate model to: %s\n', modelPath);

function y = local_window_labels_from_beats(ann, type, winStart, winEnd, minBeatsPerWindow, minAbnormalFraction)
typeChars = char(type);
excludeMask = (typeChars == '+') | (typeChars == '[') | (typeChars == ']');
beatAnn = ann(~excludeMask);
beatType = typeChars(~excludeMask);

y = nan(numel(winStart), 1);
if isempty(beatAnn)
    return;
end

for i = 1:numel(winStart)
    inWin = (beatAnn >= winStart(i)) & (beatAnn <= winEnd(i));
    n = nnz(inWin);
    if n < minBeatsPerWindow
        continue;
    end

    abnormalFrac = sum(beatType(inWin) ~= 'N') / n;
    y(i) = double(abnormalFrac >= minAbnormalFraction);
end
end

function thrBest = local_threshold_for_min_recall(y_true, score_pos, targetRecall)
% Choose threshold maximizing accuracy subject to recall >= targetRecall.
y_true = y_true(:);
score_pos = score_pos(:);

[fpr, tpr, thr] = perfcurve(y_true, score_pos, 1);
thr = thr(:);
tpr = tpr(:);
fpr = fpr(:);

valid = ~isnan(thr) & ~isnan(tpr) & ~isnan(fpr);
thr = thr(valid);
tpr = tpr(valid);
fpr = fpr(valid);

P = sum(y_true == 1);
N = sum(y_true == 0);
acc = (tpr * P + (1 - fpr) * N) / (P + N);

ok = (tpr >= targetRecall);
if any(ok)
    idx_ok = find(ok);
    [~, bestLocal] = max(acc(idx_ok));
    thrBest = thr(idx_ok(bestLocal));
else
    % Can't reach target recall; use lowest threshold to maximize recall.
    thrBest = min(thr);
end
end

