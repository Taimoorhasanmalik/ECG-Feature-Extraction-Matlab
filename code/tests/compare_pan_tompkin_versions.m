% compare_pan_tompkin_versions
% Loads a record, runs both the updated pan_tompkin and the baseline
% pan_tompkin_og implementations, prints percentage agreement for each
% fiducial type, and saves overlay plots to outputs/.

if ~exist('rdsamp','file')
    error('WFDB Toolbox is required. Install it from PhysioNet.');
end

%% ------------ Configuration --------------------------------------- %%
record_id = '/databases/201';
channel = 1;
seconds_to_use = 30;                                                       % adjust as needed
plot_title = sprintf('pan\\_tompkin comparison — %s ch%d', record_id, channel);
tol_ms = 40;                                                               % matching tolerance in milliseconds

%% ------------ Load record ----------------------------------------- %%
fprintf('Reading record %s (channel %d)...\n', record_id, channel);
[ecg, fs, ~] = rdsamp(record_id, channel);
if isempty(ecg)
    error('No samples returned. Check that the record exists under databases/.');
end
samples = min(size(ecg,1), seconds_to_use * fs);
ecg = ecg(1:samples,1);
t = (0:length(ecg)-1)/fs;

%% ------------ Run detectors --------------------------------------- %%
fprintf('Running updated pan_tompkin...\n');
[qrs_amp_new,qrs_i_new,Q_new,~,S_new,~,T_new,~] = pan_tompkin(ecg, fs, 0);

fprintf('Running original pan_tompkin_og...\n');
[qrs_amp_og,qrs_i_og,Q_og,~,S_og,~,T_og,~] = pan_tompkin_og(ecg, fs, 0);

fiducials = {
    struct('name','R','ref',qrs_i_og,'test',qrs_i_new)
    struct('name','Q','ref',Q_og,'test',Q_new)
    struct('name','S','ref',S_og,'test',S_new)
    struct('name','T','ref',T_og,'test',T_new)
};

tol_samples = round((tol_ms/1000)*fs);
fprintf('\nMatching tolerance: %d samples (~%d ms).\n', tol_samples, tol_ms);

results = struct('name',{},'ref_count',{},'test_count',{},'matches',{}, ...
    'recall',{},'precision',{},'f1',{});
for idx = 1:numel(fiducials)
    res = compare_peak_sets(fiducials{idx}.name, fiducials{idx}.ref, ...
        fiducials{idx}.test, tol_samples);
    results(end+1) = res; %#ok<AGROW>
    fprintf('%s: ref=%d, test=%d, matches=%d => recall %.1f%%, precision %.1f%%, F1 %.1f%%\n', ...
        res.name, res.ref_count, res.test_count, res.matches, ...
        100*res.recall, 100*res.precision, 100*res.f1);
end

%% ------------ Plot overlays --------------------------------------- %%
fig = figure('Name', plot_title, 'Color','w','Position',[100 100 1100 650]);
ecg_h = bandpass_ecg(ecg, fs);

subplot(3,1,1);
plot(t, ecg, 'Color',[0.7 0.7 0.7]); hold on;
plot(t, ecg_h, 'Color',[0 0.4 0.7],'LineWidth',1.1);
scatter(t(qrs_i_og), ecg_h(qrs_i_og), 20, 'm', 'filled');
scatter(t(qrs_i_new), ecg_h(qrs_i_new), 20, 'c');
xlabel('Time (s)'); ylabel('Amplitude'); title('R peaks (OG=filled magenta, Updated=cyan hollow)');
legend({'Raw','Band-pass','R_{og}','R_{new}'},'Location','best'); grid on;

subplot(3,1,2);
scatter(t(Q_og), ecg_h(Q_og), 20, 'b', 'filled'); hold on;
scatter(t(Q_new), ecg_h(Q_new), 20, 'b');
scatter(t(S_og), ecg_h(S_og), 20, 'k', 'filled');
scatter(t(S_new), ecg_h(S_new), 20, 'k');
xlabel('Time (s)'); ylabel('Amplitude'); title('Q/S peaks (OG filled, Updated hollow)');
legend({'Q_{og}','Q_{new}','S_{og}','S_{new}'},'Location','best'); grid on;

subplot(3,1,3);
scatter(t(T_og), ecg_h(T_og), 20, 'g', 'filled'); hold on;
scatter(t(T_new), ecg_h(T_new), 20, 'g');
xlabel('Time (s)'); ylabel('Amplitude'); title('T peaks (OG filled, Updated hollow)');
legend({'T_{og}','T_{new}'},'Location','best'); grid on;

outputs_dir = fullfile(fileparts(mfilename('fullpath')),'..','outputs');
if ~exist(outputs_dir,'dir'); mkdir(outputs_dir); end
out_path = fullfile(outputs_dir,'pan_tompkin_comparison.png');
print(fig, out_path, '-dpng','-r200');
fprintf('\nSaved comparison plot to %s\n', out_path);

%% ------------ Helper functions ------------------------------------ %%
function result = compare_peak_sets(name, ref_idx, test_idx, tol_samples)
    ref_idx = unique(ref_idx(:)');
    test_idx = unique(test_idx(:)');
    matches = 0;
    used = false(size(test_idx));
    for r = ref_idx
        diffs = abs(test_idx - r);
        [min_diff, pos] = min(diffs);
        if ~isempty(min_diff) && min_diff <= tol_samples && ~used(pos)
            matches = matches + 1;
            used(pos) = true;
        end
    end
    ref_count = numel(ref_idx);
    test_count = numel(test_idx);
    recall = safe_div(matches, ref_count);
    precision = safe_div(matches, test_count);
    f1 = safe_div(2*precision*recall, precision+recall);
    result = struct('name',name,'ref_count',ref_count,'test_count',test_count, ...
        'matches',matches,'recall',recall,'precision',precision,'f1',f1);
end

function val = safe_div(num, den)
    if den == 0
        val = 0;
    else
        val = num/den;
    end
end

function ecg_h = bandpass_ecg(ecg, fs)
    if fs == 200
        ecg = ecg - mean(ecg);
        [b,a] = butter(3, 12*2/fs, 'low');
        ecg_l = filtfilt(b,a,ecg);
        [b,a] = butter(3, 5*2/fs, 'high');
        ecg_h = filtfilt(b,a,ecg_l);
    else
        [b,a] = butter(3, [5 15]*2/fs);
        ecg_h = filtfilt(b,a,ecg);
    end
    ecg_h = ecg_h ./ max(abs(ecg_h));
end
