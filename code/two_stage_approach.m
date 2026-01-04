folder = "databases/mitdb";
fileList = dir(fullfile(folder, '*.hea'));
fileList = {fileList.name};

enable_plots = false;

window_length_seconds = 5;
window_step_seconds = 5;
featureNames = {'mean'};

remove_mean_outliers = true;
outlier_robust_z_threshold = 3.5;
apply_outlier_filter_to_test = true;

% Initialize variables to collect all data
all_X = [];
all_Y = [];
% Iterate over each file
for i = 1:length(fileList)
    recordname = str2mat(fullfile(folder, fileList{i}(1:end-4))); % Remove file extension
    
    % Display file being processed
    display(['Reading ECG signal from file: ', recordname]);
    
    % Read ECG signal and annotations
    [ecg, Fs, tm] = rdsamp(recordname, 1);
    [ann, type, subtype, chan, num, comments] = rdann(recordname, 'atr', 1);

    % Rhythm Identification
    rhythm = comments(1);
    count = 1;
    my_classes = {'N', 'Not_N'};
    while count < length(ann)
        if (type(count) == '+')
            rhythm = comments(count);
        end
        comments(count) = rhythm;
        count = count + 1;
    end

    %% Feature Extraction and Labeling (no peak-based features)
    X = [];
    Y = [];

    count = 1;
    while count <= length(comments)
        rhythm = cell2mat(comments(count));
        
        % Assign rhythm type
        if  length(rhythm) == 4 && all(rhythm == '(VFL')
            rhythmType = 'Not_N';
        elseif  length(rhythm) == 4 && all(rhythm == '(AFL')
            rhythmType = 'Not_N';
        elseif length(rhythm) == 2 && all(rhythm == '(N')
            rhythmType = 'N';
        elseif length(rhythm) == 2 && all(rhythm == '(P')
            rhythmType = 'Not_N';
        elseif length(rhythm) == 3 && all(rhythm == '(VT') % New class VT
            rhythmType = 'Not_N';
        elseif length(rhythm) == 5 && all(rhythm == '(AFIB')
            rhythmType = 'Not_N';
        elseif length(rhythm) == 4 && all(rhythm == '(BII')
            rhythmType = 'Not_N';
        else
            count = count + 1; % Skip unrecognized rhythms
            continue;
        end
    
    % Find start and end of the rhythm section
    start_count = ann(count);
    while (count <= length(comments)) && ...
          (length(cell2mat(comments(count))) == length(rhythm)) && ...
          all(cell2mat(comments(count)) == rhythm)
        count = count + 1;
    end
    if count <= length(ann)
        end_count = ann(count);
    else
        end_count = length(ecg);
    end

    start_count = max(1, min(start_count, length(ecg)));
    end_count = max(1, min(end_count, length(ecg)));
    if end_count <= start_count
        continue;
    end

    segment = ecg(start_count:end_count);
    segment_len = length(segment);
    if segment_len < 2
        continue;
    end

    window_len = max(2, round(window_length_seconds * Fs));
    step_len = max(1, round(window_step_seconds * Fs));

    if segment_len < window_len
        window_starts = 1;
    else
        window_starts = 1:step_len:(segment_len - window_len + 1);
    end

    for window_start = window_starts
        window_end = min(window_start + window_len - 1, segment_len);
        xw = double(segment(window_start:window_end));

        X = [X; mean(xw)];
        if strcmp(rhythmType, 'Not_N')
            Y = [Y; 1];
        else
            Y = [Y; 0];
        end
    end
end

all_X = [all_X; X]; 
all_Y = [all_Y; Y]; 
end
%%
X = all_X;
Y = all_Y;

% Print dataset statistics
fprintf('\nDataset Statistics:\n');
fprintf('Total samples: %d\n', length(Y));
fprintf('Not_N samples: %d (%.2f%%)\n', sum(Y==1), 100*sum(Y==1)/length(Y));
fprintf('N samples: %d (%.2f%%)\n', sum(Y==0), 100*sum(Y==0)/length(Y));

% Check for feature correlations
fprintf('\nFeature Correlations:\n');
if size(X, 2) < 2
    fprintf('Only one feature (%s); skipping correlation matrix.\n', featureNames{1});
else
    correlation_matrix = corrcoef(X);
    feature_names = featureNames;
    for i = 1:length(feature_names)
        for j = i+1:length(feature_names)
            fprintf('Correlation between %s and %s: %.4f\n', ...
                feature_names{i}, feature_names{j}, correlation_matrix(i,j));
        end
    end
end

% Cross-validation setup
num_folds = 5;
cv = cvpartition(Y, 'KFold', num_folds, 'Stratify', true);

%% Train several lightweight models (CPU-friendly)
model_names = {'LinearSVM', 'Logistic', 'LDA', 'NaiveBayes'};
cv_results = struct();

fprintf('\nTraining models using only feature: %s\n', featureNames{1});
fprintf('Outlier removal on mean: %d (robust z <= %.2f)\n', remove_mean_outliers, outlier_robust_z_threshold);

for m = 1:length(model_names)
    model_name = model_names{m};

    fold_accuracies = NaN(num_folds, 1);
    fold_precisions = NaN(num_folds, 1);
    fold_recalls = NaN(num_folds, 1);
    fold_f1_scores = NaN(num_folds, 1);
    fold_aucs = NaN(num_folds, 1);

    fprintf('\nModel: %s\n', model_name);
    for fold = 1:num_folds
        train_idx = training(cv, fold);
        test_idx = test(cv, fold);

        X_train = X(train_idx, :);
        y_train = Y(train_idx);
        X_test = X(test_idx, :);
        y_test = Y(test_idx);

        if remove_mean_outliers && strcmp(featureNames{1}, 'mean')
            [X_train, y_train, outlier_center, outlier_scale] = filter_outliers_robust_z(X_train, y_train, outlier_robust_z_threshold);
            if apply_outlier_filter_to_test
                [X_test, y_test] = filter_outliers_robust_z_apply(X_test, y_test, outlier_robust_z_threshold, outlier_center, outlier_scale);
            end
        end

        if isempty(y_train) || isempty(y_test) || numel(unique(y_train)) < 2 || numel(unique(y_test)) < 2
            fprintf('Fold %d skipped (insufficient samples/classes after outlier filtering)\n', fold);
            continue;
        end

        weights = compute_class_weights(y_train);
        model = train_classifier(model_name, X_train, y_train, weights);
        [y_pred, score_pos] = predict_positive_score(model, X_test, 1);

        [accuracy, precision, recall, f1_score, AUC] = compute_metrics(y_test, y_pred, score_pos);

        fold_accuracies(fold) = accuracy;
        fold_precisions(fold) = precision;
        fold_recalls(fold) = recall;
        fold_f1_scores(fold) = f1_score;
        fold_aucs(fold) = AUC;

        fprintf('Fold %d/%d: Acc %.2f%%  F1 %.4f  AUC %.4f\n', fold, num_folds, accuracy*100, f1_score, AUC);
    end

    cv_results.(model_name).fold_accuracies = fold_accuracies;
    cv_results.(model_name).fold_precisions = fold_precisions;
    cv_results.(model_name).fold_recalls = fold_recalls;
    cv_results.(model_name).fold_f1_scores = fold_f1_scores;
    cv_results.(model_name).fold_aucs = fold_aucs;
    cv_results.(model_name).mean_accuracy = mean(fold_accuracies, 'omitnan');
    cv_results.(model_name).mean_precision = mean(fold_precisions, 'omitnan');
    cv_results.(model_name).mean_recall = mean(fold_recalls, 'omitnan');
    cv_results.(model_name).mean_f1 = mean(fold_f1_scores, 'omitnan');
    cv_results.(model_name).mean_auc = mean(fold_aucs, 'omitnan');

    fprintf('%s mean: Acc %.2f%%  F1 %.4f  AUC %.4f\n', ...
        model_name, cv_results.(model_name).mean_accuracy*100, cv_results.(model_name).mean_f1, cv_results.(model_name).mean_auc);
end

best_model_name = model_names{1};
best_auc = -Inf;
for m = 1:length(model_names)
    model_name = model_names{m};
    if cv_results.(model_name).mean_auc > best_auc
        best_auc = cv_results.(model_name).mean_auc;
        best_model_name = model_name;
    end
end
fprintf('\nBest model by mean AUC: %s (AUC = %.4f)\n', best_model_name, best_auc);

% Train final models on full dataset (optionally removing outliers)
X_train_all = X;
y_train_all = Y;
outlier_center = NaN;
outlier_scale = NaN;
if remove_mean_outliers && strcmp(featureNames{1}, 'mean')
    [X_train_all, y_train_all, outlier_center, outlier_scale] = filter_outliers_robust_z(X_train_all, y_train_all, outlier_robust_z_threshold);
end

trained_models = struct();
weights_all = compute_class_weights(y_train_all);
for m = 1:length(model_names)
    model_name = model_names{m};
    trained_models.(model_name) = train_classifier(model_name, X_train_all, y_train_all, weights_all);
end

% Save models + CV results
fprintf('\nSaving models and results...\n');
if ~exist('models', 'dir')
    mkdir('models');
end
save('models/two_stage_mean_models.mat', ...
    'trained_models', 'cv_results', 'featureNames', 'Fs', 'best_model_name', 'best_auc', ...
    'remove_mean_outliers', 'outlier_robust_z_threshold', 'apply_outlier_filter_to_test', ...
    'outlier_center', 'outlier_scale');
fprintf('Saved: models/two_stage_mean_models.mat\n');

function [x_filtered, y_filtered, center, scale] = filter_outliers_robust_z(x, y, z_threshold)
x = double(x(:));
y = y(:);
center = median(x, 'omitnan');
scale = mad(x, 1);
if scale == 0 || isnan(scale)
    keep = ~isnan(x) & ~isinf(x);
else
    z = 0.6745 * (x - center) / scale;
    keep = abs(z) <= z_threshold & ~isnan(z) & ~isinf(z);
end
x_filtered = x(keep);
y_filtered = y(keep);
end

function [x_filtered, y_filtered] = filter_outliers_robust_z_apply(x, y, z_threshold, center, scale)
x = double(x(:));
y = y(:);
if scale == 0 || isnan(scale)
    keep = ~isnan(x) & ~isinf(x);
else
    z = 0.6745 * (x - center) / scale;
    keep = abs(z) <= z_threshold & ~isnan(z) & ~isinf(z);
end
x_filtered = x(keep);
y_filtered = y(keep);
end

function weights = compute_class_weights(y)
y = y(:);
num_pos = sum(y == 1);
num_neg = sum(y == 0);
weights = ones(size(y));
if num_pos > 0 && num_neg > 0
    weights(y == 1) = (num_neg / num_pos) * 1.5;
    weights(y == 0) = 1.2;
end
end

function model = train_classifier(model_name, X_train, y_train, weights)
switch model_name
    case 'LinearSVM'
        model = fitclinear(X_train, y_train, ...
            'Learner', 'svm', ...
            'ClassNames', [0, 1], ...
            'Weights', weights);
    case 'Logistic'
        model = fitclinear(X_train, y_train, ...
            'Learner', 'logistic', ...
            'ClassNames', [0, 1], ...
            'Weights', weights);
    case 'LDA'
        model = fitcdiscr(X_train, y_train, ...
            'DiscrimType', 'linear', ...
            'ClassNames', [0, 1], ...
            'Weights', weights);
    case 'NaiveBayes'
        model = fitcnb(X_train, y_train, ...
            'ClassNames', [0, 1], ...
            'Weights', weights);
    otherwise
        error('Unknown model: %s', model_name);
end
end

function [y_pred, score_pos] = predict_positive_score(model, X_test, positive_class)
[y_pred, scores] = predict(model, X_test);
if size(scores, 2) == 1
    score_pos = scores(:, 1);
    return;
end
pos_idx = find(model.ClassNames == positive_class, 1);
if isempty(pos_idx)
    pos_idx = size(scores, 2);
end
score_pos = scores(:, pos_idx);
end

function [accuracy, precision, recall, f1_score, AUC] = compute_metrics(y_true, y_pred, score_pos)
TP = sum(y_pred == 1 & y_true == 1);
TN = sum(y_pred == 0 & y_true == 0);
FP = sum(y_pred == 1 & y_true == 0);
FN = sum(y_pred == 0 & y_true == 1);

accuracy = (TP + TN) / (TP + TN + FP + FN);
precision = TP / (TP + FP + eps);
recall = TP / (TP + FN + eps);
f1_score = 2 * (precision * recall) / (precision + recall + eps);

if numel(unique(y_true)) < 2
    AUC = NaN;
else
    [~,~,~,AUC] = perfcurve(y_true, score_pos, 1);
end
end
