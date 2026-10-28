function [sampleLabels, artifactMask] = build_vt_vf_sample_labels( ...
    numSamples, ann, type, comments, recordBase, Fs, artifactPadSeconds)
%BUILD_VT_VF_SAMPLE_LABELS Build VT=1, VF/VFL=2, other=0 sample labels.

sampleLabels = zeros(numSamples, 1);
artifactMask = false(numSamples, 1);
ann = max(1, min(numSamples, double(ann(:))));
type = type(:);

changePoints = [];
changeLabels = [];
for annotationIdx = 1:numel(ann)
    commentText = get_annotation_comment(comments, annotationIdx);
    rhythmLabel = rhythm_to_label(commentText);
    if type(annotationIdx) == '+'
        if is_artifact_comment(commentText)
            artifactMask = mark_annotation_interval( ...
                artifactMask, ann, annotationIdx, numSamples, 0);
        elseif ~isnan(rhythmLabel)
            changePoints(end + 1, 1) = ann(annotationIdx); %#ok<AGROW>
            changeLabels(end + 1, 1) = rhythmLabel; %#ok<AGROW>
        end
    elseif ismember(type(annotationIdx), ['~', '|'])
        artifactMask = mark_point_with_padding(artifactMask, ...
            ann(annotationIdx), Fs, artifactPadSeconds);
    end
end

for annotationIdx = 1:numel(ann)
    if type(annotationIdx) == '+' && ...
            is_artifact_comment(get_annotation_comment(comments, annotationIdx))
        artifactMask = mark_annotation_interval(artifactMask, ann, ...
            annotationIdx, numSamples, round(artifactPadSeconds * Fs));
    end
end

for changeIdx = 1:numel(changePoints)
    startIdx = changePoints(changeIdx);
    if changeIdx < numel(changePoints)
        endIdx = changePoints(changeIdx + 1) - 1;
    else
        endIdx = numSamples;
    end
    sampleLabels(startIdx:endIdx) = changeLabels(changeIdx);
end

if startsWith(lower(recordBase), 'cu')
    sampleLabels = apply_cudb_vf_intervals(sampleLabels, ann, type);
    sampleLabels = mark_cudb_tachycardia_lead_in_as_vt( ...
        sampleLabels, ann, type, Fs, numSamples);
end
end

function sampleLabels = apply_cudb_vf_intervals(sampleLabels, ann, type)
openStart = [];
for annotationIdx = 1:numel(ann)
    if type(annotationIdx) == '['
        openStart = ann(annotationIdx);
    elseif type(annotationIdx) == ']' && ~isempty(openStart)
        sampleLabels(openStart:ann(annotationIdx)) = 2;
        openStart = [];
    end
end
if ~isempty(openStart)
    sampleLabels(openStart:end) = 2;
end
end

function sampleLabels = mark_cudb_tachycardia_lead_in_as_vt(sampleLabels, ann, type, Fs, numSamples)
vfStarts = ann(type == '[');
if isempty(vfStarts)
    return;
end

tachyLeadMaxSeconds = 120;
tachyRRSeconds = 0.65;
tachyMinRunBeats = 8;
tachyFastFraction = 0.75;
qrsTypes = ['N', 'L', 'R', 'a', 'V', 'F', 'J', 'A', 'S', 'E', ...
    'j', '/', 'Q', 'e', 'n'];
qrsAnn = ann(ismember(type, qrsTypes));

for vfIdx = 1:numel(vfStarts)
    vfStart = vfStarts(vfIdx);
    leadStartLimit = max(1, vfStart - round(tachyLeadMaxSeconds * Fs));
    leadBeats = qrsAnn(qrsAnn >= leadStartLimit & qrsAnn < vfStart);
    if numel(leadBeats) < tachyMinRunBeats + 1
        continue;
    end

    fastBeat = diff(leadBeats) ./ Fs <= tachyRRSeconds;
    fastDensity = movmean(double(fastBeat), ...
        [tachyMinRunBeats - 1, 0]) >= tachyFastFraction;
    if any(fastDensity)
        runStart = find(fastDensity, 1, 'first');
        tachyStart = max(1, leadBeats(max(1, runStart)));
        sampleLabels(tachyStart:min(numSamples, vfStart - 1)) = 1;
    end
end
end

function artifactMask = mark_annotation_interval(artifactMask, ann, idx, numSamples, padSamples)
startIdx = max(1, ann(idx) - padSamples);
if idx < numel(ann)
    endIdx = min(numSamples, ann(idx + 1) - 1 + padSamples);
else
    endIdx = numSamples;
end
artifactMask(startIdx:endIdx) = true;
end

function artifactMask = mark_point_with_padding(artifactMask, pointIdx, Fs, artifactPadSeconds)
padSamples = round(artifactPadSeconds * Fs);
startIdx = max(1, pointIdx - padSamples);
endIdx = min(numel(artifactMask), pointIdx + padSamples);
artifactMask(startIdx:endIdx) = true;
end

function tf = is_artifact_comment(commentText)
commentText = upper(strtrim(char(commentText)));
tf = contains(commentText, 'NOISE') || contains(commentText, 'ARTIFACT') || ...
    contains(commentText, 'ARFCT') || contains(commentText, 'DEFIB') || ...
    contains(commentText, 'SHOCK');
end

function commentText = get_annotation_comment(comments, idx)
commentText = '';
if isempty(comments) || idx > numel(comments)
    return;
end

if iscell(comments)
    value = comments{idx};
elseif isstring(comments)
    value = comments(idx);
elseif ischar(comments) && size(comments, 1) >= idx
    value = comments(idx, :);
else
    value = '';
end
if ~isempty(value)
    commentText = upper(strtrim(char(value)));
end
end

function label = rhythm_to_label(commentText)
label = NaN;
if isempty(commentText)
    return;
end

commentText = upper(strtrim(char(commentText)));
if contains(commentText, '(VF') || contains(commentText, '(VFL') || ...
        strcmp(commentText, 'VF') || strcmp(commentText, 'VFL')
    label = 2;
elseif contains(commentText, '(VT') || strcmp(commentText, 'VT')
    label = 1;
elseif startsWith(commentText, '(')
    label = 0;
end
end
