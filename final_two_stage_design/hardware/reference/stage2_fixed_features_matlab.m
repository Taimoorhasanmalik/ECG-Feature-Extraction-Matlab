function [featureUnits, scoreQ29] = stage2_fixed_features_matlab(windowQ8)
% Integer feature/scoring cross-check for the deployable Stage 2 model.
% Input is exactly 240 signed Q5.8 integer samples after the fixed SOS RTL.
% All intermediate numerators here are below 2^53, so double arithmetic is
% integer-exact. The full IIR state uses the Python arbitrary-integer model.

x = double(windowQ8(:));
assert(numel(x) == 240 && all(x == fix(x)) && all(x >= -8192 & x <= 8191));
centeredNumerator = 240*x - sum(x);
magnitudes = abs(centeredNumerator);
peak = max(magnitudes);
d = diff(x);
retained = d(4780*abs(d) > sum(abs(d)));
derivativeZero = sum((retained(1:end-1) < 0) ~= (retained(2:end) < 0));
above = false(size(x));
if peak > 0
    above = 5*magnitudes >= peak;
end
thresholdCrossings = sum(above(1:end-1) ~= above(2:end));
blockSums = sum(reshape(magnitudes, 30, 8), 1);
meanAbs = min(fix(sum(magnitudes)/57600), 2047);
featureUnits = [meanAbs, min(sum(abs(d)),65535), derivativeZero, ...
    thresholdCrossings, meanAbs, ...
    min(fix((max(blockSums)-min(blockSums))/7200),2047), ...
    min(fix(sum(abs(diff(blockSums)))/50400),2047)];
modelPath = fullfile(fileparts(fileparts(fileparts(mfilename('fullpath')))), ...
    'stage2', 'deliverable', 'stage2_hardware_model.json');
model = jsondecode(fileread(modelPath));
weights = fix(double(model.classifier.weight_fixed_point_q2_13(:)')*8192);
bias = fix(double(model.classifier.bias_fixed_point_q2_13)*8192);
featureQ16 = featureUnits .* 2.^[8,8,16,16,8,8,8];
scoreQ29 = bias*65536 + sum(featureQ16 .* weights);
end
