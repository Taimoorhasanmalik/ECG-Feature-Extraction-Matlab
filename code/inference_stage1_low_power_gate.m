%% Inference/Eval: Stage-1 Low-Power Gate (Window Features)
% Evaluates the saved stage-1 gate model against window labels derived from beat annotations.

scriptDir = fileparts(mfilename('fullpath'));
repoRoot = fileparts(scriptDir);
addpath(scriptDir);
origDir = pwd;
cd(repoRoot);
cleanupObj = onCleanup(@() cd(origDir));

modelPath = fullfile(repoRoot, 'models', 'stage1_low_power_gate_lsvm.mat');
if ~isfile(modelPath)
    error('Model not found: %s. Run code/train_stage1_low_power_gate.m first.', modelPath);
end

S = load(modelPath);
stage1_svm_model = S.stage1_svm_model;
abnormal_threshold = S.abnormal_threshold;
gateOpts = S.gateOpts;
minBeatsPerWindow = S.minBeatsPerWindow;
minAbnormalFraction = S.minAbnormalFraction;

recordDirs = S.recordDirs;
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

fprintf('Stage-1 gate inference across %d records...\n', numel(records));
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

    g = stage1_low_power_gate(ecg(:), Fs, gateOpts);
    y_win = local_window_labels_from_beats(ann, type, g.windowStartSample, g.windowEndSample, ...
        minBeatsPerWindow, minAbnormalFraction);
    keep = ~isnan(y_win);
    if nnz(keep) < 20 || numel(unique(y_win(keep))) < 2
        fprintf('Skipping metrics (insufficient labeled windows).\n');
        continue;
    end

    X = g.features(keep, :);
    y_true = y_win(keep);

    [~, scores] = predict(stage1_svm_model, X);
    y_pred = scores(:, 2) > abnormal_threshold;

    TP = sum(y_pred == 1 & y_true == 1);
    TN = sum(y_pred == 0 & y_true == 0);
    FP = sum(y_pred == 1 & y_true == 0);
    FN = sum(y_pred == 0 & y_true == 1);

    accuracy = (TP + TN) / max(1, (TP + TN + FP + FN));
    precision = TP / (TP + FP + eps);
    recall = TP / (TP + FN + eps);
    f1 = 2 * (precision * recall) / (precision + recall + eps);
    [~, ~, ~, AUC] = perfcurve(y_true, scores(:, 2), 1);

    fprintf('Acc %.3f | Prec %.3f | Rec %.3f | F1 %.3f | AUC %.3f\n', accuracy, precision, recall, f1, AUC);

    all_accuracy(end+1, 1) = accuracy; %#ok<SAGROW>
    all_precision(end+1, 1) = precision; %#ok<SAGROW>
    all_recall(end+1, 1) = recall; %#ok<SAGROW>
    all_f1(end+1, 1) = f1; %#ok<SAGROW>
    all_auc(end+1, 1) = AUC; %#ok<SAGROW>
end

fprintf('\n==== Stage-1 Gate Mean Metrics (records with both classes) ====\n');
fprintf('Mean Accuracy: %.4f\n', mean(all_accuracy, 'omitnan'));
fprintf('Mean Precision: %.4f\n', mean(all_precision, 'omitnan'));
fprintf('Mean Recall: %.4f\n', mean(all_recall, 'omitnan'));
fprintf('Mean F1: %.4f\n', mean(all_f1, 'omitnan'));
fprintf('Mean AUC: %.4f\n', mean(all_auc, 'omitnan'));

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

