% Train a VF vs Normal classifier using sliding-window features
% - Uses window statistics from pan_tompkin plus local beat density/amplitude
% - Labels windows by dominant rhythm inside each 2 s hop (VF wins ties)
% - Keeps a lightweight linear SVM with optional GPU training fallback

% Configuration
folder = 'databases/';

% Discover WFDB records
fileList = dir(fullfile(folder, '*.hea'));
fileList = {fileList.name};

% Accumulators
X = [];
Y = [];
featureNames = {'win_mean','win_variance','win_mad', ...
                'r_density','rr_mean','rr_std', ...
                'r_amp_mean','r_amp_std'};

% Iterate records
for k = 1:numel(fileList)
    recordname = fullfile(folder, fileList{k}(1:end-4)); % strip .hea
    fprintf('Reading ECG signal from file: %s\n', recordname);

    % Read ECG and annotations
    [ecg, Fs, ~] = rdsamp(recordname, 1);
    [ann, type, ~, ~, ~, comments] = rdann(recordname, 'atr', 1);

    % Peak detection (Pan–Tompkins)
    [R_vals, R_idx, Q_idx, Q_vals, S_idx, S_vals, T_idx, T_vals, ~, window_features] = pan_tompkin_og(ecg, Fs, 0);

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
        % Default all annotations to VT (CUDB "N" spans are mostly VT)
        comments = repmat({'(VT'}, size(ann));
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

    % Sliding-window aggregation from pan_tompkin window_features
    for w = 1:numel(window_features.start_idx)
        win_start = window_features.start_idx(w);
        win_end = window_features.end_idx(w);

        % Determine window rhythm label from annotations
        ann_idx = (ann >= win_start) & (ann <= win_end);
        if ~any(ann_idx)
            continue;
        end
        rhythms = comments(ann_idx);
        rhythms = cellfun(@map_rhythm_token, rhythms, 'UniformOutput', false);
        rhythms = rhythms(~cellfun(@isempty, rhythms));
        if isempty(rhythms)
            continue;
        end
        if any(strcmp(rhythms, 'VF') | strcmp(rhythms, 'VT'))
            label = 1;
        elseif all(strcmp(rhythms, 'N'))
            label = 0;
        else
            continue; % skip mixed or unsupported rhythms
        end

        % Collect features for this window
        win_duration = (win_end - win_start + 1) / Fs;
        r_mask = (R_idx >= win_start) & (R_idx <= win_end);
        r_in_win = R_idx(r_mask);
        r_amp_win = R_vals(r_mask);
        r_density = numel(r_in_win) / max(win_duration, eps);

        if numel(r_in_win) >= 2
            rr_local = diff(r_in_win) ./ Fs;
            rr_mean = mean(rr_local);
            rr_std = std(rr_local);
        else
            rr_mean = NaN;
            rr_std = NaN;
        end

        r_amp_mean = mean(r_amp_win);
        r_amp_std = std(r_amp_win);

        feat = [window_features.mean(w), window_features.variance(w), window_features.mad(w), ...
                r_density, rr_mean, rr_std, r_amp_mean, r_amp_std];
        X = [X; feat]; %#ok<AGROW>
        Y = [Y; label]; %#ok<AGROW>
    end
end

% Replace NaNs from empty RR/amp stats with zeros to keep fitcsvm happy
if any(isnan(X(:)))
    X(isnan(X)) = 0;
end
%%
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
        warning('GPU training not supported for fitcsvm on this MATLAB: %s. Falling back to CPU.');
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

function rh = map_rhythm_token(token)
    % Map WFDB rhythm tokens to concise labels used for training
    rh = '';
    if numel(token) == 3 && all(token == '(VF')
        rh = 'VF';
    elseif numel(token) == 3 && all(token == '(VT')
        rh = 'VT';
    elseif numel(token) == 2 && all(token == '(N')
        rh = 'N';
    elseif numel(token) == 4 && all(token == '(VFL')
        rh = 'VFL';
    elseif numel(token) == 5 && all(token == '(AFIB')
        rh = 'AFIB';
    elseif numel(token) == 4 && all(token == '(BII')
        rh = 'BII';
    end
end
