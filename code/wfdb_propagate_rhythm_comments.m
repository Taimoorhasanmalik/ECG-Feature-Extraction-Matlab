function commentsOut = wfdb_propagate_rhythm_comments(ann, type, commentsIn, recordname, signalLen)
%WFDB_PROPAGATE_RHYTHM_COMMENTS Propagate rhythm labels across WFDB annotations.
%   For most records, rhythm changes are indicated by annotations with type '+'.
%   For CUDB-style records (filename starts with 'cu'), rhythm segments are
%   derived from '[' and ']' markers (mapped to VT default and VF inside brackets).

commentsOut = commentsIn;
if ~iscell(commentsOut)
    commentsOut = cellstr(commentsOut);
end

[~, filename, ~] = fileparts(char(recordname));

if startsWith(filename, 'cu')
    vt_start = [];
    vt_end = [];

    for idx = 1:numel(type)
        if type(idx) == '['
            vt_start = [vt_start, ann(idx)]; %#ok<AGROW>
        elseif type(idx) == ']'
            vt_end = [vt_end, ann(idx)]; %#ok<AGROW>
        end
    end

    if numel(vt_start) > numel(vt_end)
        vt_end = [vt_end, repmat(signalLen, 1, numel(vt_start) - numel(vt_end))]; %#ok<AGROW>
    end

    for idx = 1:numel(ann)
        commentsOut{idx} = '(VT';
    end

    for seg = 1:numel(vt_start)
        start_idx = find(ann >= vt_start(seg), 1, 'first');
        end_idx = find(ann <= vt_end(seg), 1, 'last');
        if ~isempty(start_idx) && ~isempty(end_idx)
            for j = start_idx:end_idx
                commentsOut{j} = '(VF';
            end
        end
    end
else
    if isempty(commentsOut)
        return;
    end

    rhythm = commentsOut{1};
    for idx = 1:numel(ann)
        if idx <= numel(type) && type(idx) == '+'
            rhythm = commentsOut{idx};
        end
        commentsOut{idx} = rhythm;
    end
end
end

