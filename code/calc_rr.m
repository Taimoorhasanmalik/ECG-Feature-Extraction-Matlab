function RR_int = calc_rr(R_peaks_ind, Fs)
%CALC_RR Compute RR interval feature aligned to each R peak.
%   Returns a 1xN vector where N == numel(R_peaks_ind).

n = numel(R_peaks_ind);
RR_int = zeros(1, n);

if n <= 1
    return;
end

rr = diff(R_peaks_ind(:)') ./ Fs; % 1x(N-1)
mean_rr = mean(rr, 'omitnan');

RR_int(1) = mean_rr;
RR_int(2:end) = rr;
end
