display('Reading samples ECG signal from MIT-BIH Arrhythmia Database')
[ecg,Fs,tm]=rdsamp('mitdbase/207',1);

display(['Reading and plotting annotations (human labels) of QRS complexes performend on the signals'])
[ann,type,subtype,chan,num,comments] =rdann('mitdbase/207','atr',1);



%% Adding loop

%% PRE PROCESSING
[R_peaks_val, R_peaks_ind,Q_peaks_ind, Q_peaks_val,S_peaks_ind, S_peaks_val,T_peaks_ind, T_peaks_val, delay] = pan_tompkin(ecg, Fs);

% RR_int
count = 1;
RR_int = [];
for i = R_peaks_ind
    count = count +1;
    if count >2
        RR_int = [RR_int , (i-temp_i)/Fs];
    end
    temp_i = i;

end
% Calculating QS interval
i =1 ;
QS_int = [];
while i < length(S_peaks_ind)
    QS_int = [QS_int (S_peaks_ind(i)-Q_peaks_ind(i))/Fs];
    i = i+1;
end


% Using Comments
comments2 = comments;
count =1;
my_classes = ['N' , 'VFL'];
rhythm = comments(count);
while count<length(ann)
    if (type(count) == '+')
        rhythm = comments(count);
    end
    comments(count) = rhythm;

    count = count +1;
end

%%
start_count = 1;
end_count = 1;
count = 1;
VFL_R_peak_ind = []; % Initialize to store R peak indexes
VFL_Q_peak_ind = []; % Initialize to store Q peak indexes
VFL_T_peak_ind = []; % Initialize to store T peak indexes
VFL_S_peak_ind = [];

N_R_peak_ind = []; % Initialize to store R peak indexes
N_Q_peak_ind = []; % Initialize to store Q peak indexes
N_T_peak_ind = []; % Initialize to store T peak indexes
N_S_peak_ind = [];
while count <= length(comments)
    rhythm = cell2mat(comments(count));
    
    % Check if rhythm matches '(VFL'
    if (length(rhythm) == 4) && all(rhythm == '(VFL')
        start_count = ann(count);
        
        % Find the end of the VFL rhythm
        while (count <= length(comments)) && ...
              (length(cell2mat(comments(count))) == 4) && ...
              all(cell2mat(comments(count)) == '(VFL')
            count = count + 1;
        end
        
        
        end_count = ann(count); % Mark the end of VFL section
        
        % Get R peak indices within the VFL section
        VFL_R_peak_ind = [VFL_R_peak_ind, R_peaks_ind((R_peaks_ind > start_count) & (R_peaks_ind < end_count))];
        VFL_Q_peak_ind = [VFL_Q_peak_ind, Q_peaks_ind((Q_peaks_ind > start_count) & (Q_peaks_ind < end_count))];
        VFL_T_peak_ind = [VFL_T_peak_ind, T_peaks_ind((T_peaks_ind > start_count) & (T_peaks_ind < end_count))];
        VFL_S_peak_ind = [VFL_S_peak_ind, S_peaks_ind((S_peaks_ind > start_count) & (S_peaks_ind < end_count))];
    
    else 
        if (length(rhythm) == 2) && all(rhythm == '(N')
        start_count = ann(count);
        
        % Find the end of the VFL rhythm
        while (count <= length(comments)) && ...
              (length(cell2mat(comments(count))) == 2) && ...
              all(cell2mat(comments(count)) == '(N')
            count = count + 1;
        end
        
        end_count = ann(count); % Mark the end of VFL section
        
        % Get R peak indices within the VFL section
        N_R_peak_ind = [N_R_peak_ind, R_peaks_ind((R_peaks_ind > start_count) & (R_peaks_ind < end_count))];
        N_Q_peak_ind = [N_Q_peak_ind, Q_peaks_ind((Q_peaks_ind > start_count) & (Q_peaks_ind < end_count))];
        N_T_peak_ind = [N_T_peak_ind, T_peaks_ind((T_peaks_ind > start_count) & (T_peaks_ind < end_count))];
        N_S_peak_ind = [N_S_peak_ind, S_peaks_ind((S_peaks_ind > start_count) & (S_peaks_ind < end_count))];
        else count = count + 1; % Move to the next comment
    end
    
    end
   

end
N_RR_int= calc_rr (N_R_peak_ind, Fs);
VFL_RR_int = calc_rr (VFL_R_peak_ind,Fs);
N_QS_int= calc_qs (N_Q_peak_ind,N_S_peak_ind, Fs);
VFL_QS_int = calc_qs (VFL_Q_peak_ind,VFL_S_peak_ind,Fs);

%% Structured Approach
% Initialize the main data structure to hold arrhythmia features
arrhythmiaData = struct();

count = 1;
while count <= length(comments)
    rhythm = cell2mat(comments(count));
    
    % Identify the rhythm type
    if (length(rhythm) == 4) && all(rhythm == '(VFL')
        rhythmType = 'VFL';
    elseif (length(rhythm) == 2) && all(rhythm == '(N')
        rhythmType = 'N';
    else
        count = count + 1; % Skip unrecognized rhythms
        continue;
    end
    
    % If rhythmType doesn't exist in arrhythmiaData, initialize it
    if ~isfield(arrhythmiaData, rhythmType)
        arrhythmiaData.(rhythmType).R_peak_ind = [];
        arrhythmiaData.(rhythmType).Q_peak_ind = [];
        arrhythmiaData.(rhythmType).T_peak_ind = [];
        arrhythmiaData.(rhythmType).S_peak_ind = [];
    end
    
    % Find the start and end of the current rhythm section
    start_count = ann(count);
    while (count <= length(comments)) && ...
          (length(cell2mat(comments(count))) == length(rhythm)) && ...
          all(cell2mat(comments(count)) == rhythm)
        count = count + 1;
    end
    end_count = ann(count); % Mark the end of the section
    
    % Update peak indices for the current rhythm
    arrhythmiaData.(rhythmType).R_peak_ind = [arrhythmiaData.(rhythmType).R_peak_ind, ...
        R_peaks_ind((R_peaks_ind > start_count) & (R_peaks_ind < end_count))];
    arrhythmiaData.(rhythmType).Q_peak_ind = [arrhythmiaData.(rhythmType).Q_peak_ind, ...
        Q_peaks_ind((Q_peaks_ind > start_count) & (Q_peaks_ind < end_count))];
    arrhythmiaData.(rhythmType).T_peak_ind = [arrhythmiaData.(rhythmType).T_peak_ind, ...
        T_peaks_ind((T_peaks_ind > start_count) & (T_peaks_ind < end_count))];
    arrhythmiaData.(rhythmType).S_peak_ind = [arrhythmiaData.(rhythmType).S_peak_ind, ...
        S_peaks_ind((S_peaks_ind > start_count) & (S_peaks_ind < end_count))];
end

% Calculate RR and QS intervals for each rhythm
rhythms = fieldnames(arrhythmiaData);
for i = 1:length(rhythms)
    rhythmType = rhythms{i};
    arrhythmiaData.(rhythmType).RR_int = calc_rr(arrhythmiaData.(rhythmType).R_peak_ind, Fs);
    arrhythmiaData.(rhythmType).QS_int = calc_qs(arrhythmiaData.(rhythmType).Q_peak_ind, ...
                                                 arrhythmiaData.(rhythmType).S_peak_ind, Fs);
end

%% Trying Structured SVM ====================================
%% Prepare Features and Labels
% Collect features dynamically from `arrhythmiaData`
rhythmTypes = fieldnames(arrhythmiaData);
featureNames = {'R_peak_ind', 'Q_peak_ind', 'S_peak_ind', 'T_peak_ind', 'RR_int', 'QS_int'};
X = [];
Y = [];

% Assign numerical labels to each rhythm type
labelMapping = containers.Map(rhythmTypes, 1:length(rhythmTypes));

for i = 1:length(rhythmTypes)
    rhythmType = rhythmTypes{i};
    label = labelMapping(rhythmType);
    
    % Extract features for the current rhythm
    rhythmData = arrhythmiaData.(rhythmType);
    numObservations = length(rhythmData.R_peak_ind); % Assuming R_peak_ind determines observation count
    
    % Initialize a temporary feature matrix
    tempX = zeros(numObservations, length(featureNames));
    
    for j = 1:length(featureNames)
        feature = rhythmData.(featureNames{j});
        if ~isempty(feature)
            % Resize feature vector to match `numObservations` if necessary
            tempX(:, j) = feature(:);
        end
    end
    
    % Append the features and labels
    X = [X; tempX]; % Append features
    Y = [Y; label * ones(numObservations, 1)]; % Append corresponding labels
end

%% Split Data into Training and Testing Sets
% Randomize data order
rand_num = randperm(size(X, 1));
X = X(rand_num, :);
Y = Y(rand_num);

% Split into training and testing sets (80/20 split)
trainIdx = 1:round(0.8 * length(Y));
testIdx = round(0.8 * length(Y)) + 1:length(Y);

X_train = X(trainIdx, :);
y_train = Y(trainIdx);

X_test = X(testIdx, :);
y_test = Y(testIdx);

%% Cross-Validation Partition
y_train = y_train(:); % Ensure column vector
y_test = y_test(:);
c = cvpartition(y_train, 'k', 5);

%% Feature Selection
opts = statset('display', 'iter');
classf = @(train_data, train_labels, test_data, test_labels) ...
    sum(predict(fitcsvm(train_data, train_labels, 'KernelFunction', 'rbf'), test_data) ~= test_labels);

[fs, history] = sequentialfs(classf, X_train, y_train, 'cv', c, 'options', opts, 'nfeatures', 4);

%% Train SVM with Optimized Hyperparameters
X_train_w_best_feature = X_train(:, fs);

Md1 = fitcsvm(X_train_w_best_feature, y_train, 'KernelFunction', 'linear', ...
    'OptimizeHyperparameters', 'auto', ...
    'HyperparameterOptimizationOptions', struct('AcquisitionFunctionName', ...
    'expected-improvement-plus', 'ShowPlots', true));

%% Evaluate Final Test Set Accuracy
X_test_w_best_feature = X_test(:, fs);
test_accuracy_for_iter = sum((predict(Md1, X_test_w_best_feature) == y_test)) / length(y_test) * 100;

%% Display Results
fprintf('Test accuracy: %.2f%%\n', test_accuracy_for_iter);

