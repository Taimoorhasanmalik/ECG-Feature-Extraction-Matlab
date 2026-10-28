function verify_fixed_reference_matlab(vectorDir)
% Cross-check the Python/RTL golden vectors with MATLAB fixed-point math.
% Generate vectors first with fixed_stage2.py into a temporary directory.
vectorDir = string(vectorDir);
rawHex = readlines(fullfile(vectorDir,'input.mem'));
rawHex = rawHex(strlength(rawHex)>0);
raw = hex2dec(rawHex);
raw(raw>=2^31) = raw(raw>=2^31)-2^32;
filterHex = readlines(fullfile(vectorDir,'filter.mem'));
filterHex = filterHex(strlength(filterHex)>0);
expectedFilter = hex2dec(filterHex);
expectedFilter(expectedFilter>=8192) = expectedFilter(expectedFilter>=8192)-16384;
actualFilter = stage2_fixed_filter_matlab(int64(raw));
assert(isequal(double(actualFilter),double(expectedFilter)), ...
    'MATLAB fixed filter differs from RTL/Python golden vectors');
expectedFeatures = readmatrix(fullfile(vectorDir,'features.csv'));
expectedScores = readmatrix(fullfile(vectorDir,'scores_dec.csv'));
for k = 1:size(expectedFeatures,1)
    startIndex = (k-1)*120+1;
    [f,score] = stage2_fixed_features_matlab(actualFilter(startIndex:startIndex+239));
    assert(isequal(double(f),double(expectedFeatures(k,:))), ...
        'MATLAB Stage 2 feature mismatch in window %d',k-1);
    assert(score==expectedScores(k), ...
        'MATLAB Stage 2 score mismatch in window %d',k-1);
end
fprintf('PASS: MATLAB exact filter samples, features, scores for %d windows.\n', ...
    size(expectedFeatures,1));
end
