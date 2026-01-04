function result = stage1_low_power_gate(ecg, Fs, varargin)
%STAGE1_LOW_POWER_GATE Low-power gate to decide when to run Pan-Tompkins.
%
% This implements a 2-tier workflow:
%   Tier A (always-on): 2 s window, 1 s hop, cheap features + hysteresis gate.
%   Tier B (expensive): run Pan-Tompkins + full feature extraction only when gate is ON.
%
% Features (per window) computed from baseline-removed ECG:
%   - mav_ecg : mean(abs(x))
%   - var_ecg : mean(x.^2)  (energy proxy)
%   - ll_ecg  : mean(abs(diff(x)))   (line length)
%   - qrsE    : mean(abs(bandpass(x, ~5–15 Hz))) using cheap 1st-order IIR cascade
%   - ratio   : qrsE / (mav_ecg + eps)
%
% Decision:
%   - If opts.modelPath is provided, uses the saved SVM model to obtain scores.
%   - Otherwise uses `ratio` as the score.
%
% Hysteresis:
%   - ON  if score > Th_on for K consecutive windows
%   - OFF if score < Th_off for M consecutive windows
%   - Minimum ON duration enforced
%
% Usage (offline):
%   opts = struct();
%   opts.targetFs = 125;           % optional downsample for Tier A
%   opts.windowSec = 2;
%   opts.hopSec = 1;
%   opts.Th_on = 0.20;             % tune
%   opts.Th_off = 0.15;            % tune (must be < Th_on)
%   opts.K_on = 2;
%   opts.M_off = 3;
%   opts.minOnSec = 5;
%   result = stage1_low_power_gate(ecg, Fs, opts);
%
% Result fields:
%   - gateFs, windowSec, hopSec
%   - windowStartSample, windowEndSample (in original ecg sample indices)
%   - features (Nx5), featureNames
%   - score (Nx1), decision (Nx1), gateOn (Nx1)
%   - onIntervalsSec (Px2), dutyCycle

if nargin < 2
    error('stage1_low_power_gate requires at least ecg and Fs.');
end

if isempty(ecg)
    result = local_empty_result(Fs, Fs, local_default_opts(Fs));
    return;
end

if ~isscalar(Fs) || Fs <= 0
    error('Fs must be a positive scalar.');
end

if isempty(varargin)
    opts = struct();
elseif isstruct(varargin{1})
    opts = varargin{1};
else
    % Name/value form: stage1_low_power_gate(ecg, Fs, 'targetFs', 125, ...)
    if mod(numel(varargin), 2) ~= 0
        error('Name/value arguments must come in pairs.');
    end
    opts = struct(varargin{:});
end

defaults = local_default_opts(Fs);
opts = local_merge_opts(defaults, opts);

% Basic validation/clamping
opts.targetFs = max(1, double(opts.targetFs));
opts.windowSec = max(0.1, double(opts.windowSec));
opts.hopSec = max(0.05, double(opts.hopSec));
opts.dcCutoffHz = max(0.05, double(opts.dcCutoffHz));
opts.qrsHpHz = max(0.1, double(opts.qrsHpHz));
opts.qrsLpHz = max(opts.qrsHpHz + 0.1, double(opts.qrsLpHz));
opts.K_on = max(1, round(double(opts.K_on)));
opts.M_off = max(1, round(double(opts.M_off)));
opts.minOnSec = max(0, double(opts.minOnSec));

if isfield(opts, 'modelPath')
    opts.modelPath = string(opts.modelPath);
else
    opts.modelPath = "";
end

ecg = ecg(:);

% --- Tier A sampling rate (optional downsample) ---
gateFs = Fs;
decim = max(1, floor(Fs / opts.targetFs));
if decim > 1
    gateFs = Fs / decim;
    % Very cheap anti-alias: moving average (good enough for gating)
    ecg_gate = movmean(ecg, decim, 'Endpoints', 'shrink');
    ecg_gate = ecg_gate(1:decim:end);
else
    ecg_gate = ecg;
end

% --- Baseline/DC removal via 1st-order IIR tracker ---
% dc[n] = (1-a)*x[n] + a*dc[n-1]
a_dc = exp(-2*pi*opts.dcCutoffHz/gateFs);
dc = filter(1 - a_dc, [1, -a_dc], ecg_gate);
x = ecg_gate - dc;

% --- Cheap bandpass around QRS (cascade 1st-order HP + 1st-order LP) ---
y = local_highpass_1pole(x, gateFs, opts.qrsHpHz);
y = local_lowpass_1pole(y, gateFs, opts.qrsLpHz);

% --- Windowing (2 s with 1 s hop by default) ---
winSamp = max(1, round(opts.windowSec * gateFs));
hopSamp = max(1, round(opts.hopSec * gateFs));
if numel(x) < winSamp
    result = local_empty_result(Fs, gateFs, opts);
    return;
end

winStarts = 1:hopSamp:(numel(x) - winSamp + 1);
winEnds = winStarts + winSamp - 1;
nWin = numel(winStarts);

% --- O(1) window feature computation using cumulative sums ---
eps0 = 1e-9;

cs_x = [0; cumsum(x)];
cs_x2 = [0; cumsum(x.^2)];
dx = abs(diff(x));
cs_dx = [0; cumsum(dx)];
cs_abs_y = [0; cumsum(abs(y))];

features = zeros(nWin, 5);
for i = 1:nWin
    s = winStarts(i);
    e = winEnds(i);

    sumX = cs_x(e+1) - cs_x(s);
    sumX2 = cs_x2(e+1) - cs_x2(s);
    mav = mean(abs(x(s:e)), 'omitnan'); % abs not cumulative here: OK at window rate

    % Energy proxy (mean square); mean is ~0 after DC removal
    var_ecg = sumX2 / winSamp;

    % Line length mean(abs(diff(x))) over window samples
    if winSamp >= 2
        ll = (cs_dx(e) - cs_dx(s)) / (winSamp - 1);
    else
        ll = 0;
    end

    % QRS-band energy proxy
    qrsE = (cs_abs_y(e+1) - cs_abs_y(s)) / winSamp;

    ratio = qrsE / (mav + eps0);

    features(i, :) = [mav, var_ecg, ll, qrsE, ratio];
end

featureNames = {'mav_ecg', 'var_ecg', 'll_ecg', 'qrsE', 'ratio'};

% --- Scoring (model or heuristic) ---
score = features(:, 5); % default: ratio
usedModel = false;
modelThreshold = NaN;

if strlength(opts.modelPath) > 0 && isfile(opts.modelPath)
    S = load(opts.modelPath);
    if isfield(S, 'stage1_svm_model')
        usedModel = true;
        model = S.stage1_svm_model;

        % If the model was trained on different features, you can map here.
        % This gate expects the saved model to accept 5 window features.
        [~, scores] = predict(model, features);
        score = scores(:, 2);

        if isfield(S, 'abnormal_threshold')
            modelThreshold = S.abnormal_threshold;
        end
    end
end

% --- Thresholds ---
Th_on = opts.Th_on;
Th_off = opts.Th_off;

if isnan(Th_on) || isnan(Th_off)
    % Safe default heuristics:
    % - If using model and it saved a threshold, use it as Th_on.
    % - Otherwise pick a conservative quantile-based threshold.
    if usedModel && ~isnan(modelThreshold)
        Th_on = modelThreshold;
    elseif usedModel
        Th_on = median(score, 'omitnan');
    else
        Th_on = quantile(score, 0.75);
    end

    Th_off = Th_on * 0.85;
end

if Th_off >= Th_on
    Th_off = Th_on * 0.85;
end

decision = score > Th_on;

% --- Hysteresis gating ---
K_on = opts.K_on;
M_off = opts.M_off;
minOnWindows = max(0, ceil(opts.minOnSec / opts.hopSec));

gateOn = false(nWin, 1);
isOn = false;
onCount = 0;
offCount = 0;
onHold = 0;

for i = 1:nWin
    if isOn
        onHold = max(0, onHold - 1);
        if score(i) < Th_off
            offCount = offCount + 1;
        else
            offCount = 0;
        end

        if onHold == 0 && offCount >= M_off
            isOn = false;
            onCount = 0;
            offCount = 0;
        end
    else
        if decision(i)
            onCount = onCount + 1;
        else
            onCount = 0;
        end

        if onCount >= K_on
            isOn = true;
            onHold = minOnWindows;
            onCount = 0;
            offCount = 0;
        end
    end

    gateOn(i) = isOn;
end

% --- Convert to original sample indices (before decimation) ---
windowStartSample = (winStarts - 1) * decim + 1;
windowEndSample = (winEnds - 1) * decim + 1;

onIntervalsSec = local_intervals_from_mask(gateOn, winStarts, gateFs, opts.windowSec);
dutyCycle = mean(gateOn);

result = struct();
result.Fs = Fs;
result.gateFs = gateFs;
result.decimFactor = decim;
result.windowSec = opts.windowSec;
result.hopSec = opts.hopSec;
result.dcCutoffHz = opts.dcCutoffHz;
result.qrsHpHz = opts.qrsHpHz;
result.qrsLpHz = opts.qrsLpHz;
result.featureNames = featureNames;
result.features = features;
result.score = score;
result.usedModel = usedModel;
result.Th_on = Th_on;
result.Th_off = Th_off;
result.K_on = K_on;
result.M_off = M_off;
result.minOnSec = opts.minOnSec;
result.windowStartSample = windowStartSample;
result.windowEndSample = windowEndSample;
result.decision = decision;
result.gateOn = gateOn;
result.onIntervalsSec = onIntervalsSec;
result.dutyCycle = dutyCycle;
end

function y = local_lowpass_1pole(x, Fs, fc)
if fc >= Fs/2
    y = x;
    return;
end
a = exp(-2*pi*fc/Fs);
y = filter(1 - a, [1, -a], x);
end

function y = local_highpass_1pole(x, Fs, fc)
if fc <= 0
    y = x;
    return;
end
a = exp(-2*pi*fc/Fs);
% Classic 1st-order high-pass: y[n] = a*(y[n-1] + x[n] - x[n-1])
y = zeros(size(x));
if isempty(x)
    return;
end
y(1) = 0;
for n = 2:numel(x)
    y(n) = a * (y(n-1) + x(n) - x(n-1));
end
end

function intervals = local_intervals_from_mask(mask, winStarts, gateFs, windowSec)
mask = logical(mask(:));
winStarts = winStarts(:);
if isempty(mask) || ~any(mask) || numel(mask) ~= numel(winStarts)
    intervals = zeros(0, 2);
    return;
end

edges = diff([false; mask; false]);
startWins = find(edges == 1);
endWins = find(edges == -1) - 1;

intervals = zeros(numel(startWins), 2);
winLen = max(1, round(windowSec * gateFs));
for i = 1:numel(startWins)
    sSample = winStarts(startWins(i));
    eSample = winStarts(endWins(i)) + winLen - 1;

    intervals(i, 1) = (sSample - 1) / gateFs;
    intervals(i, 2) = (eSample - 1) / gateFs;
end
end

function result = local_empty_result(Fs, gateFs, opts)
result = struct();
result.Fs = Fs;
result.gateFs = gateFs;
result.decimFactor = 1;
result.windowSec = opts.windowSec;
result.hopSec = opts.hopSec;
result.featureNames = {'mav_ecg', 'var_ecg', 'll_ecg', 'qrsE', 'ratio'};
result.features = zeros(0, 5);
result.score = zeros(0, 1);
result.usedModel = false;
result.Th_on = opts.Th_on;
result.Th_off = opts.Th_off;
result.K_on = opts.K_on;
result.M_off = opts.M_off;
result.minOnSec = opts.minOnSec;
result.windowStartSample = zeros(0, 1);
result.windowEndSample = zeros(0, 1);
result.decision = false(0, 1);
result.gateOn = false(0, 1);
result.onIntervalsSec = zeros(0, 2);
result.dutyCycle = 0;
end

function defaults = local_default_opts(Fs)
defaults = struct();
defaults.targetFs = Fs;
defaults.windowSec = 2;
defaults.hopSec = 1;
defaults.dcCutoffHz = 0.5;
defaults.qrsHpHz = 5;
defaults.qrsLpHz = 15;
defaults.modelPath = "";
defaults.Th_on = NaN;
defaults.Th_off = NaN;
defaults.K_on = 2;
defaults.M_off = 3;
defaults.minOnSec = 5;
end

function out = local_merge_opts(defaults, opts)
out = defaults;
if isempty(opts)
    return;
end
names = fieldnames(opts);
for i = 1:numel(names)
    out.(names{i}) = opts.(names{i});
end
end
