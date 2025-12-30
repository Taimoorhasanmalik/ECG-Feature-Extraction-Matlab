%% Stage-1 Inference: Normal vs Abnormal (binary)
% Evaluates the saved stage-1 model against available WFDB rhythm labels.

scriptDir = fileparts(mfilename('fullpath'));
repoRoot = fileparts(scriptDir);
addpath(scriptDir);
origDir = pwd;
cd(repoRoot);
cleanupObj = onCleanup(@() cd(origDir));
modelPath = fullfile(repoRoot, 'models', 'stage1_normal_vs_abnormal.mat');

if isfile(modelPath)
    % Older .mat files may not contain all variables; load what exists.
    load(modelPath);
else
    error('Stage-1 model not found: %s. Run code/train_stage1_normal_abnormal.m first.', modelPath);
end

if ~exist('stage1_svm_model', 'var')
    error('Stage-1 model file is missing `stage1_svm_model`: %s. Re-train with code/train_stage1_normal_abnormal.m.', modelPath);
end

if ~exist('featureNames', 'var') || isempty(featureNames)
    featureNames = {'R_peak_vals', 'Q_peak_vals', 'S_peak_vals', 'T_peak_vals', 'RR_int', 'QS_int'};
end

if ~exist('abnormal_threshold', 'var') || isempty(abnormal_threshold)
    abnormal_threshold = 0;
end

if ~exist('recordDirs', 'var') || isempty(recordDirs)
    recordDirs = [
        "Database/mitdb", ...
        "Database/cudb", ...
        "Database/vfdb" ...
    ];
    recordDirs = recordDirs(isfolder(recordDirs));
    if isempty(recordDirs)
        recordDirs = "databases";
    end
end

records = {};
for d = 1:numel(recordDirs)
    heaFiles = dir(fullfile(recordDirs(d), '*.hea'));
    for k = 1:numel(heaFiles)
        records{end+1, 1} = fullfile(recordDirs(d), heaFiles(k).name(1:end-4)); %#ok<SAGROW>
    end
end

all_accuracy = [];
all_precision = [];
all_recall = [];
all_f1 = [];
all_auc = [];

fprintf('Stage-1 inference across %d records...\n', numel(records));

for recIdx = 1:numel(records)
    recordname = char(records{recIdx});
    fprintf('\nProcessing: %s\n', recordname);

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

    [~, R_peaks_ind, Q_peaks_ind, ~, S_peaks_ind, ~, T_peaks_ind, ~, ~] = pan_tompkin(ecg, Fs, 0);
    if isempty(R_peaks_ind) || isempty(Q_peaks_ind) || isempty(S_peaks_ind) || isempty(T_peaks_ind)
        continue;
    end

    nPeaks = min([numel(R_peaks_ind), numel(Q_peaks_ind), numel(S_peaks_ind), numel(T_peaks_ind)]);
    R_peaks_ind = R_peaks_ind(1:nPeaks);
    Q_peaks_ind = Q_peaks_ind(1:nPeaks);
    S_peaks_ind = S_peaks_ind(1:nPeaks);
    T_peaks_ind = T_peaks_ind(1:nPeaks);

    typeChars = char(type);
    excludeMask = (typeChars == '+') | (typeChars == '[') | (typeChars == ']');
    beatAnn = ann(~excludeMask);
    beatType = typeChars(~excludeMask);
    if isempty(beatAnn)
        continue;
    end

    tolerance = round(0.15 * Fs);
    matchedPeakIdx = [];
    y_true = [];

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
            y_true(end+1, 1) = (beatType(b) ~= 'N'); %#ok<AGROW>
        end
    end

    if isempty(matchedPeakIdx) || numel(unique(y_true)) < 2
        fprintf('Skipping metrics (need both classes + matched peaks).\n');
        continue;
    end

    R_ind = R_peaks_ind(matchedPeakIdx);
    Q_ind = Q_peaks_ind(matchedPeakIdx);
    S_ind = S_peaks_ind(matchedPeakIdx);
    T_ind = T_peaks_ind(matchedPeakIdx);

    R_vals = ecg(R_ind);
    Q_vals = ecg(Q_ind);
    S_vals = ecg(S_ind);
    T_vals = ecg(T_ind);

    RR_int = calc_rr(R_ind, Fs);
    QS_int = calc_qs(Q_ind, S_ind, Fs);

    obs = min([numel(R_vals), numel(Q_vals), numel(S_vals), numel(T_vals), numel(RR_int), numel(QS_int), numel(y_true)]);
    X = [ ...
        R_vals(1:obs), ...
        Q_vals(1:obs), ...
        S_vals(1:obs), ...
        T_vals(1:obs), ...
        RR_int(1:obs)', ...
        QS_int(1:obs)' ...
    ];
    y_true = y_true(1:obs);

    [~, scores] = predict(stage1_svm_model, X);
    y_pred = scores(:, 2) > abnormal_threshold;

    TP = sum(y_pred == 1 & y_true == 1);
    TN = sum(y_pred == 0 & y_true == 0);
    FP = sum(y_pred == 1 & y_true == 0);
    FN = sum(y_pred == 0 & y_true == 1);

    accuracy = (TP + TN) / max(1, (TP + TN + FP + FN));
    precision = TP / (TP + FP + eps);
    recall = TP / (TP + FN + eps);
    f1_score = 2 * (precision * recall) / (precision + recall + eps);

    [~, ~, ~, AUC] = perfcurve(y_true, scores(:, 2), 1);

    fprintf('Acc %.3f | Prec %.3f | Rec %.3f | F1 %.3f | AUC %.3f\n', accuracy, precision, recall, f1_score, AUC);

    all_accuracy = [all_accuracy; accuracy]; %#ok<AGROW>
    all_precision = [all_precision; precision]; %#ok<AGROW>
    all_recall = [all_recall; recall]; %#ok<AGROW>
    all_f1 = [all_f1; f1_score]; %#ok<AGROW>
    all_auc = [all_auc; AUC]; %#ok<AGROW>
end

fprintf('\n==== Stage-1 Mean Metrics (records with both classes) ====\n');
fprintf('Mean Accuracy: %.4f\n', mean(all_accuracy, 'omitnan'));
fprintf('Mean Precision: %.4f\n', mean(all_precision, 'omitnan'));
fprintf('Mean Recall: %.4f\n', mean(all_recall, 'omitnan'));
fprintf('Mean F1: %.4f\n', mean(all_f1, 'omitnan'));
fprintf('Mean AUC: %.4f\n', mean(all_auc, 'omitnan'));
