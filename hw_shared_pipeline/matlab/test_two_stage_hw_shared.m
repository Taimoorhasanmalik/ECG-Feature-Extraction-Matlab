%% End-to-end test of the hardware-shared two-stage design.
%
% Stage 1: the DEPLOYED model, read-only from final_two_stage_design/stage1
%   (Q3.8 -> causal 3rd-order 5 Hz high-pass -> Q3.8, 4 features, 2-of-3
%   vote gate). Its features are computed with the SHARED Q5.8-wide feature
%   engine and checked bit-for-bit against the original Stage 1 feature code.
% Stage 2: the shared-chain model from hw_shared_pipeline/stage2 (same Q3.8
%   front end, causal 3rd-order 1 Hz high-pass -> Q5.8, same feature engine,
%   6 features, fixed-point linear SVM).
%
% Stage 2 models:
%   loro    - every record is classified by a model trained without it
%             (honest cross-patient end-to-end number)
%   alldata - the deployment model (in-sample for every record)
% Stage 2 power modes:
%   always_warm - Stage 2 filter and window run continuously; only its
%                 feature pass and MAC are gated by Stage 1 (no warm-up)
%   cold_start  - Stage 2 fully power-gated: when Stage 1's gate fires at the
%                 end of window a, Stage 2's filter starts from zero state;
%                 only windows that lie entirely after power-on count
% Ground truth: every VT / VF-family window of the 38-record SEED96 pool
% (from stage2_shared_alldata.mat). "Sustained" view drops VT episodes
% shorter than 30 windows (non-sustained VT), keeps all VF.
%
% Modifies no existing file.

clear;
clc;

thisDir = fileparts(mfilename('fullpath'));
pipelineRoot = fileparts(thisDir);
repoRoot = fileparts(pipelineRoot);
databasesRoot = fullfile(fileparts(repoRoot), "databases");
vfdbFolder = fullfile(databasesRoot, "mit-bih-malignant-ventricular-ectopy-database-1.0.0");
cudbFolder = fullfile(databasesRoot, "cu-ventricular-tachyarrhythmia-database-1.0.0");

fs = 120;
windowLength = 240;
stepLength = 120;
windowSeconds = 2.0;
thresholdFraction = 0.20;
blockLength = 30;

% ---- Stage 1 (deployed, read-only) ----
stage1Data = load(fullfile(repoRoot, "final_two_stage_design", "stage1", "models", ...
    "stage1_normal_vs_abnormal_window_quantized_q3_8_fix_meanonly_pthighpass_recall90_guard98_robust_lsvm_120hz_without_rms_amplitude_robust_range.mat"));
stage1Model = stage1Data.normal_abnormal_svm_model;
stage1Threshold = stage1Data.decisionThreshold;
[b1, a1] = butter(3, 5 / (fs / 2), 'high');

% ---- Stage 2 (shared chain) ----
deploy = load(fullfile(pipelineRoot, "stage2", "results", "stage2_shared_alldata.mat"));
loro = load(fullfile(pipelineRoot, "stage2", "results", "stage2_shared_loro_weights.mat"));
featureIntegerBits = double(deploy.feature_integer_bits);
featureFractionBits = double(deploy.feature_fraction_bits);
vtLabel = double(deploy.vt_label);
vfLabel = double(deploy.vf_label);
deployWeight = reshape(double(deploy.combined_weight_q), 1, []);
deployBias = double(deploy.combined_bias_q);
loroRecords = strtrim(string(loro.record_id));
[b2, a2] = butter(double(deploy.highpass_order), double(deploy.highpass_hz) / (fs / 2), 'high');

gtRecord = reshape(strtrim(string(deploy.test_record_id)), [], 1);
gtStart = double(deploy.test_start_sample(:));
gtEnd = double(deploy.test_end_sample(:));
gtLabel = double(deploy.test_true_label(:));
sustained = sustained_mask(gtRecord, gtStart, gtLabel, vtLabel, stepLength, 30);
records = unique(gtRecord, 'stable');

models = ["loro", "alldata"];
modes = ["always_warm", "cold_start"];
% columns: [isVT, gateActive, ready(always), ready(cold), correct per model x mode]
results = zeros(numel(gtLabel), 4 + numel(models) * numel(modes));
engineMaxDiff = 0;

for r = 1:numel(records)
    recordId = records(r);
    parts = strsplit(recordId, "/");
    if parts(1) == "vfdb"
        recordPath = fullfile(vfdbFolder, parts(2));
    else
        recordPath = fullfile(cudbFolder, parts(2));
    end
    [ecgRaw, sourceFs] = local_rdsamp_212(recordPath, 1);
    ecgRaw = interpolate_nonfinite(ecgRaw);
    ecgRaw = resample_ecg_only(ecgRaw, sourceFs, fs);
    shared = quantize_signed_q_format(ecgRaw, 3, 8);   % one shared front end

    % Stage 1 stream
    ecg1 = shared;
    ecg1(~isfinite(ecg1)) = 0;
    ecg1 = quantize_signed_q_format(filter(b1, a1, ecg1), 3, 8);
    numWindows = floor((numel(ecg1) - windowLength) / stepLength) + 1;
    X1 = zeros(numWindows, 4);
    windowStart = zeros(numWindows, 1);
    for w = 1:numWindows
        s0 = (w - 1) * stepLength + 1;
        windowStart(w) = s0 - 1;
        seg = ecg1(s0:s0 + windowLength - 1);
        X1(w, :) = original_stage1_features(seg, windowLength, windowSeconds, thresholdFraction);
        fe = shared_engine_features(seg, windowLength, windowSeconds, thresholdFraction, 5, 8, blockLength);
        engineMaxDiff = max(engineMaxDiff, max(abs(fe(1:4) - X1(w, :))));
    end
    [~, scores1] = predict(stage1Model, X1);
    baseAbnormal = scores1(:, 2) >= stage1Threshold;
    votes = movsum(double(baseAbnormal), [2 0]);
    gate = votes >= 2;
    runStart = zeros(numWindows, 1);
    for w = 1:numWindows
        if gate(w)
            if w > 1 && gate(w - 1)
                runStart(w) = runStart(w - 1);
            else
                runStart(w) = w;
            end
        end
    end

    % Stage 2 streams
    ecg2Warm = quantize_signed_q_format(filter(b2, a2, shared), 5, 8);
    coldCache = containers.Map('KeyType', 'double', 'ValueType', 'any');
    loroIdx = find(loroRecords == recordId, 1);
    weightSets = {reshape(double(loro.weight_q(loroIdx, :)), 1, []), deployWeight};
    biasSets = {double(loro.bias_q(loroIdx)), deployBias};

    idx = find(gtRecord == recordId);
    for k = idx'
        [~, w1] = min(abs(windowStart - gtStart(k)));
        isVT = gtLabel(k) == vtLabel;
        results(k, 1) = isVT;
        results(k, 2) = gate(w1);
        results(k, 3) = gate(w1);
        powerOn = -1;
        if gate(w1)
            powerOn = windowStart(runStart(w1)) + windowLength;   % gate decided at end of first active window
        end
        results(k, 4) = gate(w1) && gtStart(k) >= powerOn;

        segWarm = ecg2Warm(gtStart(k) + 1:gtEnd(k));
        segCold = [];
        if results(k, 4)
            if ~isKey(coldCache, powerOn)
                coldCache(powerOn) = quantize_signed_q_format(filter(b2, a2, shared(powerOn + 1:end)), 5, 8);
            end
            coldSignal = coldCache(powerOn);
            segCold = coldSignal(gtStart(k) - powerOn + 1:gtEnd(k) - powerOn);
        end

        col = 5;
        for m = 1:numel(models)
            for md = 1:numel(modes)
                ready = results(k, 2 + md);
                if ready
                    if md == 1
                        seg = segWarm;
                    else
                        seg = segCold;
                    end
                    f = shared_engine_features(seg, windowLength, windowSeconds, thresholdFraction, 5, 8, blockLength);
                    for j = 1:numel(f)
                        f(j) = quantize_signed_q_format(f(j), featureIntegerBits(j), featureFractionBits(j));
                    end
                    if sum(f .* weightSets{m}) + biasSets{m} > 0
                        predicted = vfLabel;
                    else
                        predicted = vtLabel;
                    end
                    results(k, col) = predicted == gtLabel(k);
                end
                col = col + 1;
            end
        end
    end
    fprintf('%-12s %5d Stage-1 windows, %4d ground-truth windows\n', recordId, numWindows, numel(idx));
end

fprintf('\nStage 1 features: shared Q5.8 engine vs original Stage 1 code, max |diff| = %.3g\n', engineMaxDiff);

views = {"ALL VT/VF windows", true(size(gtLabel)); "SUSTAINED view (VT episodes >= 30 windows, all VF)", sustained};
for v = 1:size(views, 1)
    rows = views{v, 2};
    isVT = results(rows, 1) == 1;
    gateOn = results(rows, 2) == 1;
    fprintf('\n=== %s: %d VT, %d VF windows ===\n', views{v, 1}, sum(isVT), sum(~isVT));
    fprintf('Stage 1 gate recall: VT %.4f | VF %.4f\n', mean(gateOn(isVT)), mean(gateOn(~isVT)));
    col = 5;
    for m = 1:numel(models)
        for md = 1:numel(modes)
            ready = results(rows, 2 + md) == 1;
            correct = results(rows, col) == 1;
            fprintf('  Stage 2 %-7s %-11s | ready VT %.4f VF %.4f | Stage 2 acc when ready %.4f | END-TO-END VT %.4f VF %.4f overall %.4f\n', ...
                models(m), modes(md), mean(ready(isVT)), mean(ready(~isVT)), mean(correct(ready)), ...
                mean(correct(isVT)), mean(correct(~isVT)), mean(correct));
            col = col + 1;
        end
    end
end

%% ---- functions ----

function mask = sustained_mask(recordIds, starts, labels, vtLabel, stepLength, minWindows)
mask = true(size(labels));
for r = unique(recordIds, 'stable')'
    idx = find(recordIds == r);
    [~, order] = sort(starts(idx));
    idx = idx(order);
    runBegin = 1;
    for j = 2:numel(idx) + 1
        if j > numel(idx) || starts(idx(j)) - starts(idx(j - 1)) ~= stepLength || labels(idx(j)) ~= labels(idx(j - 1))
            run = idx(runBegin:j - 1);
            if labels(run(1)) == vtLabel && numel(run) < minWindows
                mask(run) = false;
            end
            runBegin = j;
        end
    end
end
end

function f = original_stage1_features(seg, windowLength, windowSeconds, thresholdFraction)
% Exactly the deployed Stage 1 feature code (Q3.8 mean and mean_abs).
windowMean = quantize_signed_q_format(sum(seg, 'omitnan') / windowLength, 3, 8);
seg = seg - windowMean;
d = diff(seg);
meanAbs = quantize_signed_q_format(sum(abs(seg), 'omitnan') / windowLength, 3, 8);
f = [meanAbs, count_zero_crossings(d) / windowSeconds, sum(abs(d), 'omitnan') / windowSeconds, ...
    count_threshold_crossings(seg, thresholdFraction)];
end

function f = shared_engine_features(v, windowLength, windowSeconds, thresholdFraction, integerBits, fractionBits, blockLength)
v = v(:);
windowMean = quantize_signed_q_format(sum(v, 'omitnan') / windowLength, integerBits, fractionBits);
c = v - windowMean;
d = diff(c);
a = abs(c);
meanAbs = quantize_signed_q_format(sum(a, 'omitnan') / windowLength, integerBits, fractionBits);
zeroCrossings = count_zero_crossings(d) / windowSeconds;
lineLength = sum(abs(d), 'omitnan') / windowSeconds;
thresholdCrossingCount = count_threshold_crossings(c, thresholdFraction);
numBlocks = floor(windowLength / blockLength);
blockMeans = mean(reshape(a(1:numBlocks * blockLength), blockLength, numBlocks), 1);
f = [meanAbs, zeroCrossings, lineLength, thresholdCrossingCount, ...
    max(blockMeans) - min(blockMeans), mean(abs(diff(blockMeans)))];
end

function zc = count_zero_crossings(x)
x = x(:);
x = x(isfinite(x));
if length(x) < 2
    zc = 0;
    return;
end
signs = sign(x);
for k = 2:length(signs)
    if signs(k) == 0
        signs(k) = signs(k - 1);
    end
end
if signs(1) == 0
    firstNonZero = find(signs ~= 0, 1, 'first');
    if isempty(firstNonZero)
        zc = 0;
        return;
    end
    signs(1:firstNonZero - 1) = signs(firstNonZero);
end
zc = sum(signs(1:end-1) .* signs(2:end) < 0);
end

function tc = count_threshold_crossings(x, thresholdFraction)
x = x(:);
x = x(isfinite(x));
if length(x) < 2
    tc = 0;
    return;
end
threshold = thresholdFraction * max(abs(x));
if ~isfinite(threshold) || threshold <= 0
    tc = 0;
    return;
end
aboveThreshold = abs(x) >= threshold;
tc = sum(aboveThreshold(1:end-1) ~= aboveThreshold(2:end));
end

function quantizedValue = quantize_signed_q_format(value, integerBits, fractionBits)
value = double(value);
scale = 2 ^ fractionBits;
quantizedValue = fix(value * scale) / scale;
quantizedValue = min(max(quantizedValue, -2 ^ integerBits), 2 ^ integerBits - 1 / scale);
end

function result = interpolate_nonfinite(signal)
signal = double(signal(:));
finite = isfinite(signal);
result = signal;
if all(finite)
    return;
end
indices = (1:numel(signal))';
finiteIdx = indices(finite);
finiteVal = signal(finite);
missingIdx = indices(~finite);
interpolated = interp1(finiteIdx, finiteVal, missingIdx, 'linear');
interpolated(missingIdx < finiteIdx(1)) = finiteVal(1);
interpolated(missingIdx > finiteIdx(end)) = finiteVal(end);
result(~finite) = interpolated;
end

function targetEcg = resample_ecg_only(ecg, sourceFs, targetFs)
ecg = double(ecg(:));
if abs(sourceFs - targetFs) < 1e-6 || isempty(ecg)
    targetEcg = ecg;
    return;
end
sourceTime = (0:numel(ecg) - 1)' ./ sourceFs;
targetTime = (0:floor(sourceTime(end) * targetFs))' ./ targetFs;
targetEcg = interp1(sourceTime, ecg, targetTime, 'linear', 'extrap');
end

function [signal, Fs] = local_rdsamp_212(recordname, channel)
heaFile = [char(recordname), '.hea'];
fid = fopen(heaFile, 'r');
if fid < 0
    error('Could not open header file: %s', heaFile);
end
cleanup = onCleanup(@() fclose(fid));
headerParts = strsplit(strtrim(fgetl(fid)));
numSignals = str2double(headerParts{2});
Fs = str2double(headerParts{3});
numSamples = str2double(headerParts{4});
signalInfo = cell(numSignals, 1);
for k = 1:numSignals
    signalInfo{k} = strsplit(strtrim(fgetl(fid)));
end
datFile = fullfile(fileparts(heaFile), signalInfo{channel}{1});
gain = str2double(signalInfo{channel}{3});
baseline = str2double(signalInfo{channel}{5});
fidDat = fopen(datFile, 'r');
if fidDat < 0
    error('Could not open data file: %s', datFile);
end
datCleanup = onCleanup(@() fclose(fidDat));
bytes = fread(fidDat, inf, 'uint8=>double');
bytes = reshape(bytes(1:floor(numel(bytes) / 3) * 3), 3, [])';
firstSample = bytes(:, 1) + 256 * bitand(bytes(:, 2), 15);
secondSample = bytes(:, 3) + 256 * bitshift(bytes(:, 2), -4);
firstSample(firstSample >= 2048) = firstSample(firstSample >= 2048) - 4096;
secondSample(secondSample >= 2048) = secondSample(secondSample >= 2048) - 4096;
if numSignals == 1
    adc = reshape([firstSample.'; secondSample.'], [], 1);
elseif channel == 1
    adc = firstSample;
else
    adc = secondSample;
end
adc = adc(1:min(numSamples, numel(adc)));
adc(adc == -2048) = NaN;
signal = (adc - baseline) ./ gain;
end
