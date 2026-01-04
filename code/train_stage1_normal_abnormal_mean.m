%% Stage-1 Training (Windowed Features): Normal vs Abnormal (LSVM)
% Windowing:
%   - 2 second window
%   - 1 second overlap
% Features per window:
%   - mean, std, RMS, mean(|x|), mean(|diff(x)|)
% Label per window (from beat annotations):
%   - class 0 (Normal): all beats in the window are 'N'
%   - class 1 (Abnormal): any beat in the window is not 'N'

rng(0);

scriptDir = fileparts(mfilename('fullpath'));
repoRoot = fileparts(scriptDir);
addpath(scriptDir);
origDir = pwd;
cd(repoRoot);
cleanupObj = onCleanup(@() cd(origDir));

recordDirs = ["Database/mitdb", "Database/cudb", "Database/vfdb"];
if ~isfolder(recordDirs)
    recordDirs = ["Database/mitdb", "Database/cudb", "Database/vfdb"];
    recordDirs = recordDirs(isfolder(recordDirs));
end

records = {};
for d = 1:numel(recordDirs)
    heaFiles = dir(fullfile(recordDirs(d), '*.hea'));
    for k = 1:numel(heaFiles)
        records{end+1, 1} = fullfile(recordDirs(d), heaFiles(k).name(1:end-4)); %#ok<SAGROW>
    end
end

fprintf('Stage-1 (window features): found %d records across %d folders.\n', numel(records), numel(recordDirs));

windowSec = 4;
overlapSec = 2;
hopSec = windowSec - overlapSec;

% Window label smoothing (improves separability for window features)
minBeatsPerWindow = 3;
minAbnormalFraction = 0.25; % label abnormal if >= 25% beats are non-'N'


featureNames = {'mean_ecg', 'std_ecg', 'rms_ecg', 'mav_ecg', 'mad_ecg'};
X_all = [];
Y_all = [];

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

    ecg = ecg(:);

    % Use beat annotation symbols for labeling:
    % class 0: 'N' (normal beat), class 1: everything else (abnormal beat)
    typeChars = char(type);
    excludeMask = (typeChars == '+') | (typeChars == '[') | (typeChars == ']');
    beatAnn = ann(~excludeMask);
    beatType = typeChars(~excludeMask);
    if isempty(beatAnn)
        continue;
    end

    winSamples = round(windowSec * Fs);
    hopSamples = round(hopSec * Fs);
    if hopSamples <= 0 || numel(ecg) < winSamples
        continue;
    end
    winStarts = 1:hopSamples:(numel(ecg) - winSamples + 1);
    winFeatures = zeros(numel(winStarts), numel(featureNames));
    winLabels = nan(numel(winStarts), 1);

    for w = 1:numel(winStarts)
        s = winStarts(w);
        e = s + winSamples - 1;

        x = ecg(s:e);

        mean_ecg = mean(x, 'omitnan');
        std_ecg = std(x, 0, 'omitnan');
        rms_ecg = sqrt(mean(x.^2, 'omitnan'));
        mav_ecg = mean(abs(x), 'omitnan');
        mad_ecg = mean(abs(diff(x)), 'omitnan');

        winFeatures(w, :) = [mean_ecg, std_ecg, rms_ecg, mav_ecg, mad_ecg];

        inWin = (beatAnn >= s) & (beatAnn <= e);
        if ~any(inWin)
            continue;
        end

        beatsInWin = beatType(inWin);
        numBeats = numel(beatsInWin);
        if numBeats < minBeatsPerWindow
            continue;
        end
        abnormalFrac = sum(beatsInWin ~= 'N') / numBeats;
        winLabels(w) = double(abnormalFrac >= minAbnormalFraction);
    end


    keep = ~isnan(winLabels);
    if ~any(keep)
        continue;
    end

    X_all = [X_all; winFeatures(keep, :)]; %#ok<AGROW>
    Y_all = [Y_all; winLabels(keep)]; %#ok<AGROW>
end

fprintf('\nStage-1 Dataset (window features):\n');
fprintf('Total windows: %d\n', numel(Y_all));
fprintf('Normal windows: %d (%.2f%%)\n', sum(Y_all == 0), 100 * sum(Y_all == 0) / max(1, numel(Y_all)));
fprintf('Abnormal windows: %d (%.2f%%)\n', sum(Y_all == 1), 100 * sum(Y_all == 1) / max(1, numel(Y_all)));
fprintf('Unique labels present: %s\n', mat2str(unique(Y_all)'));
% Quick single-feature screening vs label
fprintf('\nSingle-feature screening (vs window label):\n');
for k = 1:numel(featureNames)
    x = X_all(:, k);
    r = corr(x, Y_all, 'Rows', 'complete');
    if any(Y_all == 0) && any(Y_all == 1)
        [~, ~, ~, auc] = perfcurve(Y_all, x, 1);
    else
        auc = NaN;
    end
    fprintf('%s: corr=%.4f, AUC=%.4f\n', featureNames{k}, r, auc);
end


if isempty(X_all) || numel(unique(Y_all)) < 2
    error('Stage-1: need at least 2 classes (Normal and Abnormal).');
end

% Cross-validation
num_folds = 5;
cv = cvpartition(Y_all, 'KFold', num_folds, 'Stratify', true);

fold_accuracies = zeros(num_folds, 1);
fold_precisions = zeros(num_folds, 1);
fold_recalls = zeros(num_folds, 1);
fold_f1_scores = zeros(num_folds, 1);
fold_aucs = zeros(num_folds, 1);

abnormal_threshold = 0; % Fallback; will be tuned for recall
targetRecall = 0.80;    % Increase to favor higher recall
fnCost = 3;             % False-negative cost multiplier (1->0)
cost = [0 1; fnCost 0]; % row=true class, col=pred class (ClassNames=[0 1])
fold_thresholds = zeros(num_folds, 1);

fprintf('\nStage-1 %d-fold cross-validation (LSVM, window features)...\n', num_folds);
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
    fold_threshold = local_threshold_for_recall(y_train, scores_train(:, 2), targetRecall, abnormal_threshold);
    fold_thresholds(fold) = fold_threshold;

    y_pred_train = scores_train(:, 2) > fold_threshold;
    TP_tr = sum(y_pred_train == 1 & y_train == 1);
    FN_tr = sum(y_pred_train == 0 & y_train == 1);
    recall_train = TP_tr / (TP_tr + FN_tr + eps);

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

    if any(y_test == 1) && any(y_test == 0)
        [~, ~, ~, AUC] = perfcurve(y_test, scores(:, 2), 1);
    else
        AUC = NaN;
    end

    fold_accuracies(fold) = accuracy;
    fold_precisions(fold) = precision;
    fold_recalls(fold) = recall;
    fold_f1_scores(fold) = f1_score;
    fold_aucs(fold) = AUC;

    fprintf('Fold %d/%d | Thr %.3f | TrainRec %.3f | Acc %.2f%% | Prec %.3f | Rec %.3f | F1 %.3f | AUC %.3f\n', ...
        fold, num_folds, fold_threshold, recall_train, accuracy * 100, precision, recall, f1_score, AUC);
end

fprintf('\nStage-1 Overall:\n');
fprintf('Mean Accuracy: %.2f%% ± %.2f%%\n', mean(fold_accuracies) * 100, std(fold_accuracies) * 100);
fprintf('Mean Precision: %.4f ± %.4f\n', mean(fold_precisions, 'omitnan'), std(fold_precisions, 'omitnan'));
fprintf('Mean Recall: %.4f ± %.4f\n', mean(fold_recalls, 'omitnan'), std(fold_recalls, 'omitnan'));
fprintf('Mean F1: %.4f ± %.4f\n', mean(fold_f1_scores, 'omitnan'), std(fold_f1_scores, 'omitnan'));
fprintf('Mean AUC: %.4f ± %.4f\n', mean(fold_aucs, 'omitnan'), std(fold_aucs, 'omitnan'));
fprintf('Mean tuned threshold: %.4f ± %.4f (targetRecall=%.2f, fnCost=%g)\n', mean(fold_thresholds), std(fold_thresholds), targetRecall, fnCost);

% Train final model on all data and save
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
abnormal_threshold = local_threshold_for_recall(Y_all, scores_all(:, 2), targetRecall, abnormal_threshold);

modelsDir = fullfile(repoRoot, 'models');
if ~isfolder(modelsDir)
    mkdir(modelsDir);
end

save(fullfile(modelsDir, 'stage1_normal_vs_abnormal_window_features_lsvm.mat'), ...
    'stage1_svm_model', 'featureNames', 'recordDirs', 'abnormal_threshold', ...
    'windowSec', 'overlapSec', 'hopSec', 'minBeatsPerWindow', 'minAbnormalFraction', ...
    'targetRecall', 'fnCost', 'cost');

fprintf('\nSaved stage-1 model to: %s\n', fullfile(modelsDir, 'stage1_normal_vs_abnormal_window_features_lsvm.mat'));


function fold_threshold = local_threshold_for_recall(y_true, score_pos, targetRecall, fallbackThreshold)
% Pick a decision threshold to improve accuracy while controlling recall.
% Chooses a threshold whose TRAIN recall is as close as possible to targetRecall
% but not exceeding it (recall ceiling).
y_true = y_true(:);
score_pos = score_pos(:);
fold_threshold = fallbackThreshold;

if numel(unique(y_true)) < 2
    return;
end

[fpr, tpr, thr] = perfcurve(y_true, score_pos, 1);
thr = thr(:);
tpr = tpr(:);
fpr = fpr(:);

valid = ~isnan(thr) & ~isnan(tpr) & ~isnan(fpr);
thr = thr(valid);
tpr = tpr(valid);
fpr = fpr(valid);
if isempty(thr)
    return;
end

P = sum(y_true == 1);
N = sum(y_true == 0);
acc = (tpr * P + (1 - fpr) * N) / (P + N);

ok = (tpr <= targetRecall);
if any(ok)
    idx_ok = find(ok);
    bestTpr = max(tpr(idx_ok));
    idx_close = idx_ok(tpr(idx_ok) == bestTpr);
    [~, bestLocal] = max(acc(idx_close));
    fold_threshold = thr(idx_close(bestLocal));
else
    % If all thresholds exceed target recall (unlikely), pick closest recall overall.
    [~, best] = min(abs(tpr - targetRecall));
    fold_threshold = thr(best);
end
end
