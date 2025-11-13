% test_pan_tompkin_features
% Smoke test for the updated pan_tompkin implementation. Loads a short MIT-BIH
% record, runs peak detection, validates the returned window_features struct,
% and visualizes both the derivative envelope and sliding window statistics.

if ~exist('rdsamp', 'file') || ~exist('rdann', 'file')
    error(['WFDB Toolbox not found. Install PhysioNet''s WFDB functions ' ...
           'to run this test (https://physionet.org/content/wfdb/).']);
end

record_id = '/databases/cu11';
channel = 1;
seconds_to_use = 30;                                                       % keep runtime short

fprintf('Reading record %s (channel %d)...\n', record_id, channel);
[ecg, fs, ~] = rdsamp(record_id, channel);
if isempty(ecg)
    error('No samples returned. Verify the MIT-BIH files under databases/.');
end
samples = min(size(ecg, 1), seconds_to_use * fs);
ecg = ecg(1:samples, 1);

fprintf('Running pan\\_tompkin on %d samples (fs=%d Hz)...\n', samples, fs);
[qrs_amp_raw, qrs_i_raw, Q_peaks, Q_peaks_val, S_peaks, S_peaks_val, ...
 T_peaks, T_peaks_val, delay, window_features, detector_state, P_peaks, P_peaks_val] = pan_tompkin(ecg, fs, 0);
[ann, ann_type, ~, ~, ~, ann_comments] = rdann(record_id, 'atr', 1);
ann = double(ann);
ann_idx = ann + 1;                                                         % convert WFDB 0-based samples to MATLAB
valid_ann = ann_idx <= samples;
ann = ann(valid_ann);
ann_idx = ann_idx(valid_ann);
ann_type = ann_type(valid_ann);
ann_comments = ann_comments(valid_ann);
rhythm_segments = extract_rhythm_segments(ann, ann_type, ann_comments, samples);

%% ===== Assertions to guard the new outputs =====
assert(~isempty(qrs_i_raw), 'No R peaks detected.');
assert(isstruct(window_features), 'window_features must be a struct.');
scalar_fields = {'start_idx', 'end_idx', 'mean', 'variance', 'mad'};
for f = scalar_fields
    assert(isfield(window_features, f{1}), ...
        'window_features.%s is missing.', f{1});
end
num_windows = numel(window_features.start_idx);
assert(num_windows > 0, 'No sliding windows were returned.');
assert(all(size(window_features.start_idx) == size(window_features.end_idx)), ...
    'start_idx and end_idx must align.');
assert(all(window_features.end_idx >= window_features.start_idx), ...
    'Each window end must be >= its start.');
window_durs = (window_features.end_idx - window_features.start_idx + 1) / fs;
if num_windows > 1
    assert(all(window_durs(1:num_windows-1) >= 1.8), ...
        'Early windows should cover ~2 s segments.');
end
assert(all(~isnan(window_features.mean)), 'Window means contain NaNs.');
assert(all(window_features.variance >= 0), 'Variance must be non-negative.');
assert(all(window_features.mad >= 0), 'MAD must be non-negative.');
assert(max(qrs_i_raw) <= length(ecg), ...
    'Detected R-peak index exceeds available samples.');
assert(numel(P_peaks) == numel(Q_peaks), ...
    'P peaks should align one-to-one with Q peaks.');
assert(all(P_peaks <= Q_peaks), 'Each P peak must precede its corresponding Q.');

if num_windows > 1
    span_s = (window_features.end_idx(end) - window_features.start_idx(1)) / fs;
else
    span_s = window_durs(1);
end
fprintf('Detected %d beats after %.3f s delay; %d windows span %.2f s.\n', ...
    numel(qrs_i_raw), delay / fs, num_windows, span_s);
if ~isempty(rhythm_segments)
    fprintf('\nRhythm annotations (WFDB comments):\n');
    for idx = 1:numel(rhythm_segments)
        seg = rhythm_segments(idx);
        start_t = (double(seg.start_idx) - 1) / fs;
        end_t = (double(seg.end_idx) - 1) / fs;
        fprintf('  %-6s : %.2f s – %.2f s\n', seg.label, start_t, end_t);
    end
else
    fprintf('\nNo rhythm annotations found in WFDB comments.\n');
end

%% ===== Visualize derivative envelope + window stats =====
t = (0:length(ecg)-1) / fs;
ecg_h = bandpass_ecg(ecg, fs);
env_sig = derivative_envelope(ecg_h, fs);

fig = figure('Name', 'pan\_tompkin feature validation', 'Color', 'w');
subplot(3,1,1);
plot(t, ecg, 'Color', [0.7 0.7 0.7]);
hold on;
plot(t, ecg_h, 'Color', [0 0.4 0.6], 'LineWidth', 1.1);
scatter(t(qrs_i_raw), ecg_h(qrs_i_raw), 20, 'm', 'filled');
if ~isempty(Q_peaks), scatter(t(Q_peaks), ecg_h(Q_peaks), 20, 'b', 'filled'); end
if ~isempty(S_peaks), scatter(t(S_peaks), ecg_h(S_peaks), 20, 'k', 'filled'); end
if ~isempty(T_peaks), scatter(t(T_peaks), ecg_h(T_peaks), 20, 'g', 'filled'); end
if ~isempty(P_peaks), scatter(t(P_peaks), ecg_h(P_peaks), 20, [1 0.5 0], 'filled'); end
if ~isempty(ann_idx)
    scatter(t(ann_idx), ecg_h(ann_idx), 18, [0.2 0.2 0.2], '^', 'filled');
end
highlight_windows(gca, window_features, fs);
highlight_rhythm_segments(gca, rhythm_segments, fs);
xlabel('Time (s)');
ylabel('Amplitude (mV)');
title('ECG (raw + band-pass) with fiducials on band-passed trace');
legend({'Raw ECG','Band-pass ECG','R (band-pass)','Q','S','T','P','WFDB ann'}, 'Location', 'best');
grid on;

subplot(3,1,2);
plot(t, env_sig, 'LineWidth', 1.2);
hold on;
thr_time = double(detector_state.env_locs) / fs;
thr_vals = detector_state.thr_sig;
if ~isempty(thr_time)
    stairs(thr_time, thr_vals, '--', 'Color', [0.85 0.33 0.1], 'LineWidth', 1.1);
end
xlabel('Time (s)');
ylabel('Norm. amplitude');
title('|d/dt| envelope (50 ms moving mean) with THR\\_SIG');
legend({'Envelope','THR\\_SIG'}, 'Location', 'best');
grid on;

subplot(3,1,3);
win_mid = (double(window_features.start_idx) + double(window_features.end_idx)) / (2*fs);
yyaxis left;
stairs(win_mid, window_features.mean, 'LineWidth', 1.4);
ylabel('Window mean');
yyaxis right;
stem(win_mid, window_features.variance, 'filled', 'DisplayName', 'Variance');
hold on;
plot(win_mid, window_features.mad, '--', 'LineWidth', 1.2, 'DisplayName', 'MAD');
ylabel('Window variance / MAD');
legend('Location', 'best');
xlabel('Time (s)');
title('Sliding window statistics (2 s / 1 s hop)');
grid on;

%% ===== Persist visualization for later inspection =====
this_dir = fileparts(mfilename('fullpath'));
out_dir = fullfile(this_dir, '..', 'outputs');
if ~exist(out_dir, 'dir')
    mkdir(out_dir);
end
out_path = fullfile(out_dir, 'pan_tompkin_windows.png');
print(fig, out_path, '-dpng', '-r200');
fprintf('Saved visualization to %s\n', out_path);

%% ===== Helper functions (local to this script) =====
function ecg_h = bandpass_ecg(ecg, fs)
    if fs == 200
        ecg = ecg - mean(ecg);
        Wn = 12 * 2 / fs;
        [a,b] = butter(3, Wn, 'low');
        ecg_l = filtfilt(a, b, ecg);
        lp_norm = max(abs(ecg_l));
        if lp_norm == 0
            lp_norm = 1;
        end
        ecg_l = ecg_l ./ lp_norm;
        Wn = 5 * 2 / fs;
        [a,b] = butter(3, Wn, 'high');
        ecg_h = filtfilt(a, b, ecg_l);
    else
        f1 = 5;
        f2 = 15;
        Wn = [f1 f2] * 2 / fs;
        [a,b] = butter(3, Wn);
        ecg_h = filtfilt(a, b, ecg);
    end
    hp_norm = max(abs(ecg_h));
    if hp_norm == 0
        hp_norm = 1;
    end
    ecg_h = ecg_h ./ hp_norm;
end

function env_sig = derivative_envelope(ecg_h, fs)
    if fs ~= 200
        int_c = (5-1)/(fs*1/40);
        b = interp1(1:5, [1 2 0 -2 -1].*(1/8)*fs, 1:int_c:5);
    else
        b = [1 2 0 -2 -1].*(1/8)*fs;
    end
    ecg_d = filtfilt(b, 1, ecg_h);
    ecg_d = ecg_d ./ max(abs(ecg_d));
    win_env = max(1, round(0.050 * fs));
    env_sig = movmean(abs(ecg_d), win_env);
    env_sig = env_sig ./ max(env_sig);
end

function highlight_windows(ax, window_features, fs)
    axes(ax);
    hold_state = ishold(ax);
    hold(ax, 'on');
    yl = ylim(ax);
    ypad = 0.05 * diff(yl);
    colors = [0.6 0.8 1.0; 0.8 0.9 0.6];
    for idx = 1:numel(window_features.start_idx)
        xs = double(window_features.start_idx(idx) - 1) / fs;
        xe = double(window_features.end_idx(idx) - 1) / fs;
        patch(ax, [xs xe xe xs], [yl(1) yl(1) yl(2) yl(2)], ...
              colors(mod(idx-1, size(colors,1))+1, :), ...
              'FaceAlpha', 0.08, 'EdgeColor', 'none', 'HitTest', 'off');
        text(mean([xs xe]), yl(2) - ypad, sprintf('W%d', idx), ...
             'HorizontalAlignment', 'center', 'VerticalAlignment', 'top', ...
             'Color', [0.2 0.2 0.2], 'FontSize', 8, 'Clipping', 'on');
    end
    ylim(ax, yl);
    if ~hold_state
        hold(ax, 'off');
    end
end

function segments = extract_rhythm_segments(ann, type, comments, max_samples)
    segments = struct('label',{},'start_idx',{},'end_idx',{});
    current_label = '';
    current_start = [];
    for idx = 1:numel(ann)
        if type(idx) == '+'
            if ~isempty(current_label)
                end_idx = min(double(ann(idx)), max_samples - 1);
                segments(end+1) = struct('label',current_label, ...
                    'start_idx', min(double(current_start)+1, max_samples), ...
                    'end_idx', end_idx + 1); %#ok<AGROW>
            end
            current_label = comments{idx};
            current_start = ann(idx);
        end
    end
    if ~isempty(current_label)
        segments(end+1) = struct('label',current_label, ...
            'start_idx', min(double(current_start)+1, max_samples), ...
            'end_idx', max_samples);
    end
    if ~isempty(segments)
        mask = [segments.end_idx] > [segments.start_idx];
        segments = segments(mask);
    end
end

function highlight_rhythm_segments(ax, segments, fs)
    if isempty(segments), return; end
    axes(ax);
    hold_state = ishold(ax);
    hold(ax, 'on');
    yl = ylim(ax);
    dy = diff(yl);
    labels = unique({segments.label}, 'stable');
    cmap = lines(max(1,numel(labels)));
    for idx = 1:numel(segments)
        seg = segments(idx);
        label = seg.label;
        label_idx = find(strcmp(label, labels), 1);
        color = cmap(label_idx, :);
        xs = double([seg.start_idx seg.end_idx seg.end_idx seg.start_idx] - 1) / fs;
        patch(ax, xs, [yl(1) yl(1) yl(2) yl(2)], color, ...
            'FaceAlpha', 0.05, 'EdgeColor', 'none', 'HitTest', 'off');
        text(mean(xs(1:2)), yl(2) - 0.08*dy, label, ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'top', ...
            'Color', color, 'FontSize', 8, 'Interpreter', 'none', 'HitTest', 'off');
    end
    if ~hold_state
        hold(ax, 'off');
    end
end
