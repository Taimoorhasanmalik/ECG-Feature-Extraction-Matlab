%% Stage-1 Training: Normal vs Abnormal (binary)
% Label rule:
%   Normal  = (N
%   Abnormal = any recognized rhythm label other than (N

rng(0);

scriptDir = fileparts(mfilename('fullpath'));
repoRoot = fileparts(scriptDir);
addpath(scriptDir);
origDir = pwd;
cd(repoRoot);
cleanupObj = onCleanup(@() cd(origDir));

recordDirs = ["Database/mitdb/" "Database/cudb/" "Database/vfdb/"];
recordDirs = recordDirs(isfolder(recordDirs));
if isempty(recordDirs) && isfolder("databases")
    recordDirs = "databases";
end

records = {};
for d = 1:numel(recordDirs)
    heaFiles = dir(fullfile(recordDirs(d), '*.hea'));
    for k = 1:numel(heaFiles)
        records{end+1, 1} = fullfile(recordDirs(d), heaFiles(k).name(1:end-4)); %#ok<SAGROW>
    end
end

fprintf('Stage-1: found %d records across %d folders.\n', numel(records), numel(recordDirs));

featureNames = {'R_peak_vals', 'Q_peak_vals', 'S_peak_vals', 'T_peak_vals', 'RR_int', 'QS_int'};
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

    % Peak detection
    [~, R_peaks_ind, Q_peaks_ind, ~, S_peaks_ind, ~, T_peaks_ind, ~, ~] = pan_tompkin(ecg, Fs, 0);
    if isempty(R_peaks_ind) || isempty(Q_peaks_ind) || isempty(S_peaks_ind) || isempty(T_peaks_ind)
        continue;
    end

    % Align peak arrays (assume indices are aligned per beat)
    nPeaks = min([numel(R_peaks_ind), numel(Q_peaks_ind), numel(S_peaks_ind), numel(T_peaks_ind)]);
    R_peaks_ind = R_peaks_ind(1:nPeaks);
    Q_peaks_ind = Q_peaks_ind(1:nPeaks);
    S_peaks_ind = S_peaks_ind(1:nPeaks);
    T_peaks_ind = T_peaks_ind(1:nPeaks);

    % Use beat annotation symbols for labeling:
    % class 0: 'N' (normal beat), class 1: everything else (abnormal beat)
    typeChars = char(type);
    excludeMask = (typeChars == '+') | (typeChars == '[') | (typeChars == ']');
    beatAnn = ann(~excludeMask);
    beatType = typeChars(~excludeMask);
    if isempty(beatAnn)
        continue;
    end

    tolerance = round(0.15 * Fs);
    matchedPeakIdx = [];
    matchedY = [];

    p = 1;
    for b = 1:numel(beatAnn)
        a = beatAnn(b);
        while p < nPeaks && R_peaks_ind(p) < a
            p = p + 1;
        end
        candidates = unique([max(1, p-1), min(nPeaks, p)]);
        [bestDiff, bestIdxLocal] = min(abs(R_peaks_ind(candidates) - a));
        if bestDiff <= tolerance
            bestIdx = candidates(bestIdxLocal);
            matchedPeakIdx(end+1, 1) = bestIdx; %#ok<AGROW>
            matchedY(end+1, 1) = (beatType(b) ~= 'N'); %#ok<AGROW>
        end
    end

    if isempty(matchedPeakIdx)
        continue;
    end

    matchedPeakIdx = matchedPeakIdx(:);
    matchedY = matchedY(:);

    R_ind = R_peaks_ind(matchedPeakIdx);
    Q_ind = Q_peaks_ind(matchedPeakIdx);
    S_ind = S_peaks_ind(matchedPeakIdx);
    T_ind = T_peaks_ind(matchedPeakIdx);

    % Build features
    R_vals = ecg(R_ind);
    Q_vals = ecg(Q_ind);
    S_vals = ecg(S_ind);
    T_vals = ecg(T_ind);

    RR_int = calc_rr(R_ind, Fs);
    QS_int = calc_qs(Q_ind, S_ind, Fs);

    obs = min([numel(R_vals), numel(Q_vals), numel(S_vals), numel(T_vals), numel(RR_int), numel(QS_int), numel(matchedY)]);
    if obs < 3
        continue;
    end

    tempX = [ ...
        R_vals(1:obs), ...
        Q_vals(1:obs), ...
        S_vals(1:obs), ...
        T_vals(1:obs), ...
        RR_int(1:obs)', ...
        QS_int(1:obs)' ...
    ];
    tempY = matchedY(1:obs);

    X_all = [X_all; tempX]; %#ok<AGROW>
    Y_all = [Y_all; tempY]; %#ok<AGROW>
end
%%
fprintf('\nStage-1 Dataset:\n');
fprintf('Total samples: %d\n', numel(Y_all));
fprintf('Normal samples: %d (%.2f%%)\n', sum(Y_all == 0), 100 * sum(Y_all == 0) / max(1, numel(Y_all)));
fprintf('Abnormal samples: %d (%.2f%%)\n', sum(Y_all == 1), 100 * sum(Y_all == 1) / max(1, numel(Y_all)));
fprintf('Unique labels present: %s\n', mat2str(unique(Y_all)'));

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

abnormal_threshold = 0; % SVM score threshold for class=1

fprintf('\nStage-1 %d-fold cross-validation...\n', num_folds);
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
        'KernelFunction', 'rbf', ...
        'ClassNames', [0, 1], ...
        'Standardize', true, ...
        'Weights', w);

    [~, scores] = predict(stage1_svm, X_test);
    y_pred = scores(:, 2) > abnormal_threshold;

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

    fprintf('Fold %d/%d | Acc %.2f%% | Prec %.3f | Rec %.3f | F1 %.3f | AUC %.3f\n', ...
        fold, num_folds, accuracy * 100, precision, recall, f1_score, AUC);
end

fprintf('\nStage-1 Overall:\n');
fprintf('Mean Accuracy: %.2f%% ± %.2f%%\n', mean(fold_accuracies) * 100, std(fold_accuracies) * 100);
fprintf('Mean Precision: %.4f ± %.4f\n', mean(fold_precisions, 'omitnan'), std(fold_precisions, 'omitnan'));
fprintf('Mean Recall: %.4f ± %.4f\n', mean(fold_recalls, 'omitnan'), std(fold_recalls, 'omitnan'));
fprintf('Mean F1: %.4f ± %.4f\n', mean(fold_f1_scores, 'omitnan'), std(fold_f1_scores, 'omitnan'));
fprintf('Mean AUC: %.4f ± %.4f\n', mean(fold_aucs, 'omitnan'), std(fold_aucs, 'omitnan'));

% Train final model on all data and save
n_ab = sum(Y_all == 1);
n_n = sum(Y_all == 0);
w_all = ones(size(Y_all));
if n_ab > 0 && n_n > 0
    w_all(Y_all == 1) = n_n / n_ab;
    w_all(Y_all == 0) = 1;
end

stage1_svm_model = fitcsvm(X_all, Y_all, ...
    'KernelFunction', 'rbf', ...
    'ClassNames', [0, 1], ...
    'Standardize', true, ...
    'Weights', w_all);

modelsDir = fullfile(repoRoot, 'models');
if ~isfolder(modelsDir)
    mkdir(modelsDir);
end

save(fullfile(modelsDir, 'stage1_normal_vs_abnormal.mat'), ...
    'stage1_svm_model', 'featureNames', 'recordDirs', 'abnormal_threshold');

fprintf('\nSaved stage-1 model to: %s\n', fullfile(modelsDir, 'stage1_normal_vs_abnormal.mat'));
