% Train a simple VF vs Normal classifier (clean version)
% - Keeps: data loading, rhythm labeling, feature extraction, model training
% - Removes: feature correlation checks, cross-validation, downsampling
% - Adds: optional GPU arrays with safe CPU fallback

% Configuration
folder = 'databases/';

% Discover WFDB records
fileList = dir(fullfile(folder, '*.hea'));
fileList = {fileList.name};

% Accumulators
arrhythmiaData = struct();

% Iterate records
for k = 1:numel(fileList)
    recordname = fullfile(folder, fileList{k}(1:end-4)); % strip .hea
    fprintf('Reading ECG signal from file: %s\n', recordname);

    % Read ECG and annotations
    [ecg, Fs, ~] = rdsamp(recordname, 1);
    [ann, type, ~, ~, ~, comments] = rdann(recordname, 'atr', 1);

    % Peak detection (Pan–Tompkins)
    [R_vals, R_idx, Q_idx, Q_vals, S_idx, S_vals, T_idx, T_vals, ~] = pan_tompkin_og(ecg, Fs, 0);

    % Build rhythm labels along timeline
    [~, filename] = fileparts(recordname);

    % Normalize comments cell array length to annotations length
    if ~iscell(comments)
        comments = cellstr(comments);
    end

    if startsWith(filename, 'cu')
        % For CUDB-like records, VF sections are marked by '[' and ']'
        vf_start = [];
        vf_end = [];
        for i = 1:length(type)
            if type(i) == '['
                vf_start(end+1) = ann(i); %#ok<AGROW>
            elseif type(i) == ']'
                vf_end(end+1) = ann(i); %#ok<AGROW>
            end
        end
        % Pair unclosed segments with end of signal
        if numel(vf_start) > numel(vf_end)
            vf_end = [vf_end, repmat(length(ecg), 1, numel(vf_start) - numel(vf_end))]; %#ok<AGROW>
        end
        % Default all annotations to Normal
        comments = repmat({'(N'}, size(ann));
        % Mark VF ranges
        for s = 1:numel(vf_start)
            s_idx = find(ann >= vf_start(s), 1, 'first');
            e_idx = find(ann <= vf_end(s), 1, 'last');
            if ~isempty(s_idx) && ~isempty(e_idx)
                for j = s_idx:e_idx
                    comments{j} = '(VF';
                end
            end
        end
    else
        % Propagate rhythm labels after '+' markers
        r = comments(1);
        idx = 1;
        while idx <= length(ann)
            if type(idx) == '+'
                r = comments(idx);
            end
            comments(idx) = r;
            idx = idx + 1;
        end
    end

    % Aggregate peaks by rhythm segments
    idx = 1;
    while idx <= numel(comments)
        rh = comments{idx};

        % Map rhythm token to a concise type
        if numel(rh) == 3 && all(rh == '(VF')
            rhythmType = 'VF';
        elseif numel(rh) == 2 && all(rh == '(N')
            rhythmType = 'N';
        elseif numel(rh) == 4 && all(rh == '(VFL')
            rhythmType = 'VFL';
        elseif numel(rh) == 5 && all(rh == '(AFIB')
            rhythmType = 'AFIB';
        elseif numel(rh) == 4 && all(rh == '(BII')
            rhythmType = 'BII';
        else
            idx = idx + 1;
            continue; % skip unrecognized
        end

        % Initialize bins
        if ~isfield(arrhythmiaData, rhythmType)
            arrhythmiaData.(rhythmType).R_peak_vals = [];
            arrhythmiaData.(rhythmType).R_peak_ind  = [];
            arrhythmiaData.(rhythmType).Q_peak_vals = [];
            arrhythmiaData.(rhythmType).Q_peak_ind  = [];
            arrhythmiaData.(rhythmType).S_peak_vals = [];
            arrhythmiaData.(rhythmType).S_peak_ind  = [];
            arrhythmiaData.(rhythmType).T_peak_vals = [];
        end

        % Span of this contiguous rhythm segment
        seg = rh;
        start_sample = ann(idx);
        while idx <= numel(comments) && numel(comments{idx}) == numel(seg) && all(comments{idx} == seg)
            idx = idx + 1;
        end
        if idx <= numel(ann)
            end_sample = ann(idx);
        else
            end_sample = length(ecg);
        end

        % Slice peaks within segment and append
        selR = (R_idx > start_sample) & (R_idx < end_sample);
        selQ = (Q_idx > start_sample) & (Q_idx < end_sample);
        selS = (S_idx > start_sample) & (S_idx < end_sample);
        selT = (T_idx > start_sample) & (T_idx < end_sample);

        arrhythmiaData.(rhythmType).R_peak_vals = [arrhythmiaData.(rhythmType).R_peak_vals, ecg(R_idx(selR))'];
        arrhythmiaData.(rhythmType).R_peak_ind  = [arrhythmiaData.(rhythmType).R_peak_ind,  R_idx(selR)];
        arrhythmiaData.(rhythmType).Q_peak_vals = [arrhythmiaData.(rhythmType).Q_peak_vals, ecg(Q_idx(selQ))'];
        arrhythmiaData.(rhythmType).Q_peak_ind  = [arrhythmiaData.(rhythmType).Q_peak_ind,  Q_idx(selQ)];
        arrhythmiaData.(rhythmType).S_peak_vals = [arrhythmiaData.(rhythmType).S_peak_vals, ecg(S_idx(selS))'];
        arrhythmiaData.(rhythmType).S_peak_ind  = [arrhythmiaData.(rhythmType).S_peak_ind,  S_idx(selS)];
        arrhythmiaData.(rhythmType).T_peak_vals = [arrhythmiaData.(rhythmType).T_peak_vals, ecg(T_idx(selT))'];
    end
end

% Post-process per rhythm: align array sizes and compute intervals
rhythmTypes = fieldnames(arrhythmiaData);
for i = 1:numel(rhythmTypes)
    rt = rhythmTypes{i};
    obs = min([numel(arrhythmiaData.(rt).R_peak_vals), ...
               numel(arrhythmiaData.(rt).Q_peak_vals), ...
               numel(arrhythmiaData.(rt).S_peak_vals), ...
               numel(arrhythmiaData.(rt).T_peak_vals)]);
    if obs == 0
        continue;
    end
    f = arrhythmiaData.(rt);
    f.R_peak_vals = f.R_peak_vals(1:obs);
    f.R_peak_ind  = f.R_peak_ind(1:obs);
    f.Q_peak_vals = f.Q_peak_vals(1:obs);
    f.Q_peak_ind  = f.Q_peak_ind(1:obs);
    f.S_peak_vals = f.S_peak_vals(1:obs);
    f.S_peak_ind  = f.S_peak_ind(1:obs);
    f.T_peak_vals = f.T_peak_vals(1:obs);
    % Intervals
    f.RR_int = calc_rr(f.R_peak_ind, Fs);
    f.QS_int = calc_qs(f.Q_peak_ind, f.S_peak_ind, Fs);
    arrhythmiaData.(rt) = f;
end

% Build dataset: VF (1) vs Normal (0)
featureNames = {'R_peak_vals','Q_peak_vals','S_peak_vals','T_peak_vals','RR_int','QS_int'};
validRhythms = {'VF','N'};
X = [];
Y = [];
for i = 1:numel(validRhythms)
    rt = validRhythms{i};
    if ~isfield(arrhythmiaData, rt)
        continue;
    end
    f = arrhythmiaData.(rt);
    n = numel(f.R_peak_ind);
    if n == 0
        continue;
    end
    tempX = zeros(n, numel(featureNames));
    for j = 1:numel(featureNames)
        name = featureNames{j};
        if isfield(f, name) && ~isempty(f.(name))
            tempX(:, j) = f.(name)(:);
        end
    end
    X = [X; tempX]; %#ok<AGROW>
    if strcmp(rt,'VF')
        Y = [Y; ones(n,1)]; %#ok<AGROW>
    else
        Y = [Y; zeros(n,1)]; %#ok<AGROW>
    end
end

% Dataset summary
fprintf('\nDataset Statistics (no downsampling):\n');
fprintf('Total samples: %d\n', numel(Y));
fprintf('VF samples: %d (%.2f%%)\n', sum(Y==1), 100*sum(Y==1)/max(1,numel(Y)));
fprintf('NORMAL samples: %d (%.2f%%)\n', sum(Y==0), 100*sum(Y==0)/max(1,numel(Y)));

% Train a simple linear SVM on all data (no CV)
if isempty(X)
    error('No data assembled for training. Check inputs and annotations.');
end

% Class weights similar to original script
num_vf = sum(Y == 1);
num_normal = sum(Y == 0);
class_weights = zeros(size(Y));
if num_vf > 0
    class_weights(Y == 1) = (num_normal / max(1,num_vf)) * 1.5; % emphasize VF
end
class_weights(Y == 0) = 1.2; % slight weight for Normal

% Optional GPU usage: try training with gpuArray, fall back to CPU if unsupported
useGPU = false;
try
    useGPU = (gpuDeviceCount > 0);
catch
    useGPU = false;
end

if useGPU
    Xg = gpuArray(single(X));
    Yg = gpuArray(single(Y));
    Wg = gpuArray(single(class_weights));
    try
        fprintf('Training starting using GPU arrays.\n');
        vf_svm_model = fitcsvm(Xg, Yg, ...
            'KernelFunction','linear', ...
            'ClassNames',[0,1], ...
            'Standardize',true, ...
            'Weights', Wg);
        % Model object resides on CPU even if trained from gpuArray in newer releases;
        % if not, gather will error and be skipped.
        try, vf_svm_model = gather(vf_svm_model); end %#ok<TRYNC>
        fprintf('Trained SVM using GPU arrays.\n');
    catch ME
        warning('GPU training not supported for fitcsvm on this MATLAB: %s. Falling back to CPU.', ME.message);
        vf_svm_model = fitcsvm(X, Y, ...
            'KernelFunction','linear', ...
            'ClassNames',[0,1], ...
            'Standardize',true, ...
            'Weights', class_weights);
    end
else
    vf_svm_model = fitcsvm(X, Y, ...
        'KernelFunction','linear', ...
        'ClassNames',[0,1], ...
        'Standardize',true, ...
        'Weights', class_weights);
end

% Save model and metadata
featureNames = featureNames; %#ok<NASGU>
save('vf_model.mat','vf_svm_model','featureNames','Fs','class_weights');
fprintf('Saved trained model to vf_model.mat\n');
