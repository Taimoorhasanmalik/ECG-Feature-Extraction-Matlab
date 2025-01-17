folder = "databases/";
fileList = dir(fullfile(folder, '*.hea'));
fileList = {fileList.name};

% Initialize variables to collect all data
all_X = [];
all_Y = [];
arrhythmiaData = struct();

% Iterate over each file
for i = 1:46
    recordname = str2mat(fullfile(folder, fileList{i}(1:end-4))); % Remove file extension
    
    % Display file being processed
    display(['Reading ECG signal from file: ', recordname]);
    
    % Read ECG signal and annotations
    [ecg, Fs, tm] = rdsamp(recordname, 1);
    [ann, type, subtype, chan, num, comments] = rdann(recordname, 'atr', 1);
    
    %% Preprocessing (extract peaks and features)
    [R_peaks_val, R_peaks_ind, Q_peaks_ind, Q_peaks_val, ...
     S_peaks_ind, S_peaks_val, T_peaks_ind, T_peaks_val, delay] = pan_tompkin(ecg, Fs,0);

     rhythm = comments(1);
     count = 1;
     while count < length(ann)
        if (recordname(end-3) == 'c')
            if (type(count) == '[')
                rhythm = {'(VT'};
            end    
            if (type(count) == ']')
                rhythm = {'[]'};
            end    
        elseif (type(count) == '+')
            rhythm = comments(count);
        end
        comments(count) = rhythm;
        count = count + 1;
    end

    %% Feature Extraction and Labeling
    count = 1;
    while count <= length(comments)
        rhythm = cell2mat(comments(count));
        
        % Assign rhythm type
        if  length(rhythm) == 4 && all(rhythm == '(VFL')
            rhythmType = 'VFL';
        elseif length(rhythm) == 2 && all(rhythm == '(N')
            rhythmType = 'N';
        elseif length(rhythm) == 3 && all(rhythm == '(VT') % New class VT
            rhythmType = 'VT';
        elseif length(rhythm) == 5 && all(rhythm == '(AFIB') % New class VT
            rhythmType = 'AFIB';
        elseif length(rhythm) == 4 && all(rhythm == '(BII') % New class VT
            rhythmType = 'BII';
        else
            count = count + 1; % Skip unrecognized rhythms
            continue;
        end

    % Initialize fields if rhythmType doesn't exist
    if ~isfield(arrhythmiaData, rhythmType)
        arrhythmiaData.(rhythmType).R_peak_vals = [];
        arrhythmiaData.(rhythmType).R_peak_ind = [];
        arrhythmiaData.(rhythmType).Q_peak_vals = [];
        arrhythmiaData.(rhythmType).Q_peak_ind = [];
        arrhythmiaData.(rhythmType).T_peak_vals = [];
        arrhythmiaData.(rhythmType).S_peak_vals = [];
        arrhythmiaData.(rhythmType).S_peak_ind = [];
    end
    
    % Find start and end of the rhythm section
    start_count = ann(count);
    while (count <= length(comments)) && ...
          (length(cell2mat(comments(count))) == length(rhythm)) && ...
          all(cell2mat(comments(count)) == rhythm)
        count = count + 1;
    end
    end_count = ann(count);
    
    % Update peak indices for the current rhythm
    arrhythmiaData.(rhythmType).R_peak_vals = [arrhythmiaData.(rhythmType).R_peak_vals, ...
        ecg(R_peaks_ind((R_peaks_ind > start_count) & (R_peaks_ind < end_count)))'];
    
    arrhythmiaData.(rhythmType).R_peak_ind = [arrhythmiaData.(rhythmType).R_peak_ind, ...
        R_peaks_ind((R_peaks_ind > start_count) & (R_peaks_ind < end_count))];
                
    arrhythmiaData.(rhythmType).Q_peak_vals = [arrhythmiaData.(rhythmType).Q_peak_vals, ...
        ecg(Q_peaks_ind((Q_peaks_ind > start_count) & (Q_peaks_ind < end_count)))'];

    arrhythmiaData.(rhythmType).Q_peak_ind = [arrhythmiaData.(rhythmType).Q_peak_ind, ...
        Q_peaks_ind((Q_peaks_ind > start_count) & (Q_peaks_ind < end_count))];
        
    arrhythmiaData.(rhythmType).T_peak_vals = [arrhythmiaData.(rhythmType).T_peak_vals, ...
        ecg(T_peaks_ind((T_peaks_ind > start_count) & (T_peaks_ind < end_count)))'];

    arrhythmiaData.(rhythmType).S_peak_vals = [arrhythmiaData.(rhythmType).S_peak_vals, ...
        ecg(S_peaks_ind((S_peaks_ind > start_count) & (S_peaks_ind < end_count)))'];
    arrhythmiaData.(rhythmType).S_peak_ind = [arrhythmiaData.(rhythmType).S_peak_ind, ...
        S_peaks_ind((S_peaks_ind > start_count) & (S_peaks_ind < end_count))];
end

% Calculate RR and QS intervals for each rhythm
rhythms = fieldnames(arrhythmiaData);
for i = 1:length(rhythms)
    rhythmType = rhythms{i};
    obs = min([length(arrhythmiaData.(rhythmType).R_peak_vals),length(arrhythmiaData.(rhythmType).Q_peak_vals),length(arrhythmiaData.(rhythmType).S_peak_vals),length(arrhythmiaData.(rhythmType).T_peak_vals)]);
        arrhythmiaData.(rhythmType).R_peak_vals = arrhythmiaData.(rhythmType).R_peak_vals(1:obs);
        arrhythmiaData.(rhythmType).R_peak_ind = arrhythmiaData.(rhythmType).R_peak_ind(1:obs);
        arrhythmiaData.(rhythmType).Q_peak_vals = arrhythmiaData.(rhythmType).Q_peak_vals(1:obs);
        arrhythmiaData.(rhythmType).S_peak_vals = arrhythmiaData.(rhythmType).S_peak_vals(1:obs);
        arrhythmiaData.(rhythmType).Q_peak_ind = arrhythmiaData.(rhythmType).Q_peak_ind(1:obs);
        arrhythmiaData.(rhythmType).S_peak_ind = arrhythmiaData.(rhythmType).S_peak_ind(1:obs);
        arrhythmiaData.(rhythmType).T_peak_vals = arrhythmiaData.(rhythmType).T_peak_vals(1:obs);
        

    arrhythmiaData.(rhythmType).RR_int = calc_rr(arrhythmiaData.(rhythmType).R_peak_ind, Fs);
    arrhythmiaData.(rhythmType).QS_int = calc_qs(arrhythmiaData.(rhythmType).Q_peak_ind, ...
                                                 arrhythmiaData.(rhythmType).S_peak_ind, Fs);
end

%% Prepare Features and Labels

rhythmTypes = fieldnames(arrhythmiaData);
featureNames = {'R_peak_vals', 'Q_peak_vals', 'S_peak_vals', 'T_peak_vals', 'RR_int', 'QS_int'};
X = [];
Y = [];

labelMapping = containers.Map(rhythmTypes, 1:length(rhythmTypes));

for i = 1:length(rhythmTypes)
    rhythmType = rhythmTypes{i};
    label = labelMapping(rhythmType);
    
    % Extract features
    rhythmData = arrhythmiaData.(rhythmType);
    numObservations = length(rhythmData.R_peak_ind);
    % Initialize temporary feature matrix
    tempX = zeros(numObservations, length(featureNames));
    
    for j = 1:length(featureNames)
        feature = rhythmData.(featureNames{j});
        if ~isempty(feature)
            tempX(:, j) = feature(:);
        end
    end
    
    % Append the features and labels
    X = [X; tempX]; % Append features
    Y = [Y; label * ones(numObservations, 1)]; % Append labels
end

%% Collect all features and labels from all files
all_X = [all_X; X]; 
all_Y = [all_Y; Y]; 
end

maxObservationsN = 700000; % Adjust this value as needed
% Apply limit to the number of observations for rhythm type "N"
N_indices = find(all_Y == labelMapping('N'));
if length(N_indices) > maxObservationsN
    % Randomly select indices to discard
    discard_N_indices = randsample(N_indices, length(N_indices) - maxObservationsN);
    % Keep only the selected indices
    keep_indices = setdiff(1:length(all_Y), discard_N_indices);
    all_X = all_X(keep_indices, :);
    all_Y = all_Y(keep_indices);
end



%% Split Data into Training and Testing Sets


X = all_X;
Y = all_Y;

% Split into training and testing sets (80/20 split)
trainIdx = 1:round(0.8 * length(Y));
testIdx = round(0.8 * length(Y)) + 1:length(Y);

X_train = X;
y_train = Y;

X_test = X(testIdx, :);
y_test = Y(testIdx);


%% ===================================================================== GPU NEW
% Unique classes in the labels
unique_classes = unique(Y);
num_classes = length(unique_classes);

% Initialize models and predictions
models = cell(num_classes, 1);
binary_predictions = zeros(length(Y), num_classes);

% Transfer data to GPU (optional, but not used by fitcsvm)
X_train_gpu = gpuArray(X_train);
Y_gpu = gpuArray(y_train);

% Create a DataQueue to handle progress updates
q = parallel.pool.DataQueue;
afterEach(q, @nUpdateProgress);

% Initialize progress bar
hWaitBar = waitbar(0, 'Training SVM models...');

% Function to update progress bar
function nUpdateProgress(~)
    waitbar(i/num_classes, hWaitBar);
end

% Train a binary SVM for each class using parallel computing
parfor i = 1:num_classes
    fprintf('Training binary SVM for class %d vs all...\n', unique_classes(i));
    
    % Create binary labels: 1 for current class, -1 for all others
    binary_labels = -ones(size(Y_gpu));
    binary_labels(Y_gpu == unique_classes(i)) = 1;

    % Train SVM for the current class
    models{i} = fitcsvm(X_train_gpu, binary_labels, ...
        'KernelFunction', 'linear', ...
        'ClassNames', [-1, 1], ...
        'BoxConstraint', 1, ...
        'Standardize', true);
    
    % Send progress update
    send(q, i);
end

% Close the progress bar
close(hWaitBar);

%% Testing and One-vs-All Prediction
binary_predictions = zeros(size(X_test, 1), num_classes); % Preallocate

% Transfer test data to GPU
X_test_gpu = gpuArray(X_test);

for i = 1:num_classes
    % Predict scores for each class
    [~, scores] = predict(models{i}, X_test_gpu);

    % Assign only the positive class score
    binary_predictions(:, i) = gather(scores(:, 2)); % Transfer back to CPU
end

% Assign the class with the highest score as the prediction
[~, predicted_labels] = max(binary_predictions, [], 2);

% Transfer labels back to CPU
predicted_labels = gather(predicted_labels);

%% Evaluate Performance
test_accuracy = sum(predicted_labels == Y(testIdx)) / length(Y(testIdx)) * 100;

fprintf('Test accuracy (One-vs-All): %.2f%%\n', test_accuracy);






% %% ===================================================================== GPU OLD
% % Unique classes in the labels
% unique_classes = unique(Y);
% num_classes = length(unique_classes);

% % Initialize models and predictions
% models = cell(num_classes, 1);
% binary_predictions = zeros(length(Y), num_classes);

% % Transfer data to GPU
% X_train_gpu = gpuArray(X_train);
% Y_gpu = gpuArray(Y);

% % Create a DataQueue to handle progress updates
% q = parallel.pool.DataQueue;
% afterEach(q, @nUpdateProgress);


% % Train a binary SVM for each class
% for i = 1:num_classes
%     fprintf('Training binary SVM for class %d vs all...\n', unique_classes(i));
    
%     % Create binary labels: 1 for current class, -1 for all others
%     binary_labels = -ones(size(Y_gpu));
%     binary_labels(Y_gpu == unique_classes(i)) = 1;
    
%     % Train SVM for the current class
%     models{i} = fitcsvm(X_train_gpu, binary_labels(trainIdx), ...
%         'KernelFunction', 'linear', ...
%         'ClassNames', [-1, 1], ...
%         'BoxConstraint', 1, ...
%         'Standardize', true);
% end

% %% Testing and One-vs-All Prediction
% binary_predictions = zeros(size(X_test, 1), num_classes); % Preallocate

% % Transfer test data to GPU
% X_test_gpu = gpuArray(X_test);

% for i = 1:num_classes
%     % Predict scores for each class
%     [~, scores] = predict(models{i}, X_test_gpu);

%     % Assign only the positive class score
%     binary_predictions(:, i) = gather(scores(:, 2)); % Transfer back to CPU
% end

% % Assign the class with the highest score as the prediction
% [~, predicted_labels] = max(binary_predictions, [], 2);

% % Transfer labels back to CPU
% predicted_labels = gather(predicted_labels);

% %% Evaluate Performance
% test_accuracy = sum(predicted_labels == Y(testIdx)) / length(Y(testIdx)) * 100;

% fprintf('Test accuracy (One-vs-All): %.2f%%\n', test_accuracy);






%% ===================================================================== CPU OLD

% %% One-vs-All Multiclass Classification

% % Unique classes in the labels
% unique_classes = unique(Y);
% num_classes = length(unique_classes);

% % Initialize models and predictions
% models = cell(num_classes, 1);
% binary_predictions = zeros(length(Y), num_classes);

% % Train a binary SVM for each class
% for i = 1:num_classes
%     fprintf('Training binary SVM for class %d vs all...\n', unique_classes(i));
    
%     % Create binary labels: 1 for current class, -1 for all others
%     binary_labels = -ones(size(Y));
%     binary_labels(Y == unique_classes(i)) = 1;
    
%     % Train SVM for the current class
%     models{i} = fitcsvm(X_train, binary_labels(trainIdx), ...
%         'KernelFunction', 'linear', ...
%         'ClassNames', [-1, 1], ...
%         'BoxConstraint', 1, ...
%         'Standardize', true);
% end

% %% Testing and One-vs-All Prediction
% binary_predictions = zeros(size(X_test, 1), num_classes); % Preallocate

% for i = 1:num_classes
%     % Predict scores for each class
%     [~, scores] = predict(models{i}, X_test);

%     % Assign only the positive class score
%     binary_predictions(:, i) = scores(:, 2);
% end

% % Assign the class with the highest score as the prediction
% [~, predicted_labels] = max(binary_predictions, [], 2);


% %% Evaluate Performance
% test_accuracy = sum(predicted_labels == Y(testIdx)) / length(Y(testIdx)) * 100;

% fprintf('Test accuracy (One-vs-All): %.2f%%\n', test_accuracy);


%% =====================================================================




% %% Hyperparameter Tuning with Grid Search and Cross-validation for Linear Kernel

% % Define the grid search space
% C_values = logspace(-3, 3, 7);  % Example values for C (1e-3 to 1e3)
% kernel_types = {'linear'};  % Only using linear kernel
% gamma_values = logspace(-3, 3, 7);  % Gamma values for KernelScale

% % Initialize variables to track the best model
% best_accuracy = 0;
% best_params = struct('C', NaN, 'Kernel', 'linear', 'Gamma', NaN);

% % Total number of iterations
% totalIterations = length(C_values) * length(gamma_values);

% % Create progress bar
% h = waitbar(0, 'Hyperparameter tuning in progress...');

% % Perform grid search over hyperparameters
% iteration = 0;
% for c = C_values
%     for gamma = gamma_values
%         % Train an SVM model with current hyperparameters (linear kernel)
%         model = fitcsvm(X_train, y_train, ...
%             'KernelFunction', 'linear', ...
%             'BoxConstraint', c, ...
%             'KernelScale', gamma, ...
%             'Standardize', true);

%         % Evaluate on the validation set
%         [predicted_labels, ~] = predict(model, X_val);
%         accuracy = sum(predicted_labels == y_val) / length(y_val);
        
%         % Update if this is the best accuracy
%         if accuracy > best_accuracy
%             best_accuracy = accuracy;
%             best_params.C = c;  % Update best C
%             best_params.Gamma = gamma;  % Update best Gamma
%         end
        
%         % Update progress bar
%         iteration = iteration + 1;
%         waitbar(iteration / totalIterations, h, sprintf('Processing: %d%%', round((iteration / totalIterations) * 100)));
%     end
% end

% % Close the progress bar
% close(h);

% % Display the best hyperparameters
% disp('Best hyperparameters found:');
% disp(best_params);

% %% Final Model Training with Best Hyperparameters
% final_model = fitcsvm(X, Y, ...
%     'KernelFunction', best_params.Kernel, ...
%     'BoxConstraint', best_params.C, ...
%     'KernelScale', best_params.Gamma, ...
%     'Standardize', true);

% %% Evaluate Final Model
% % Perform testing using cross-validation or hold-out test set (same as before)
% cvfinal_model = crossval(final_model);
% cvfinal_loss = kfoldLoss(cvfinal_model);
% test_accuracy = 1 - cvfinal_loss;

% fprintf('Test accuracy with tuned hyperparameters: %.2f%%\n', test_accuracy);
