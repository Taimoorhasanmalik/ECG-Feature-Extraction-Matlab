function QS_int = calc_qs(Q_peaks_ind, S_peaks_ind, Fs)
%CALC_QS Compute QS interval feature aligned to each beat.
%   Returns a 1xN vector where N == min(numel(Q_peaks_ind), numel(S_peaks_ind)).

n = min(numel(Q_peaks_ind), numel(S_peaks_ind));
QS_int = zeros(1, n);

if n == 0
    return;
end

qs = (S_peaks_ind(1:n) - Q_peaks_ind(1:n)) ./ Fs;
QS_int = qs(:)';
QS_int(1) = mean(QS_int, 'omitnan');
end
