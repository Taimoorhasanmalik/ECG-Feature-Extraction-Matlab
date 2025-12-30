function rhythmType = wfdb_parse_rhythm_type(commentCell)
%WFDB_PARSE_RHYTHM_TYPE Convert WFDB rhythm comments into a canonical label.
%   Returns '' when the comment is not a recognized rhythm label.

comment = strtrim(char(commentCell));
if isempty(comment)
    rhythmType = '';
    return;
end

if contains(comment, '(N')
    rhythmType = 'N';
elseif contains(comment, '(VFL')
    rhythmType = 'VFL';
elseif contains(comment, '(VF') || endsWith(comment, 'VF')
    rhythmType = 'VF';
elseif contains(comment, '(VT')
    rhythmType = 'VT';
elseif contains(comment, '(AFL')
    rhythmType = 'AFL';
elseif contains(comment, '(AFIB')
    rhythmType = 'AFIB';
elseif contains(comment, '(BII')
    rhythmType = 'BII';
elseif contains(comment, '(P')
    rhythmType = 'P';
else
    rhythmType = '';
end
end

