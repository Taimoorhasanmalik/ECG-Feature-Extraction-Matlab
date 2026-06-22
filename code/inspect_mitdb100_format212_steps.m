%% Inspect MITDB record 100 WFDB format-212 conversion steps
% Prints raw byte triplets, unpacked 12-bit samples, signed samples, and
% baseline/gain-scaled physical values for the first few samples.

clear;
clc;

scriptDir = fileparts(mfilename('fullpath'));
projectRoot = fileparts(fileparts(scriptDir));
recordFolder = fullfile(projectRoot, 'databases', ...
    'mit-bih-arrhythmia-database-1.0.0');
heaFile = fullfile(recordFolder, '100.hea');

headerLines = readlines(heaFile);
headerLines = headerLines(strlength(strtrim(headerLines)) > 0);
recordLine = strtrim(headerLines(1));
signalLines = headerLines(~startsWith(strtrim(headerLines), '#'));
signalLines = signalLines(2:end);

fprintf('Header file: %s\n', heaFile);
fprintf('Record line: %s\n', recordLine);

numSignals = numel(signalLines);
dataFiles = strings(numSignals, 1);
formats = zeros(numSignals, 1);
gains = zeros(numSignals, 1);
adcResolutions = zeros(numSignals, 1);
adcZeros = zeros(numSignals, 1);
initialValues = zeros(numSignals, 1);
checksums = zeros(numSignals, 1);
descriptions = strings(numSignals, 1);

for channelIdx = 1:numSignals
    parts = split(strtrim(signalLines(channelIdx)));
    dataFiles(channelIdx) = parts(1);
    formats(channelIdx) = str2double(parts(2));
    gains(channelIdx) = str2double(parts(3));
    adcResolutions(channelIdx) = str2double(parts(4));
    adcZeros(channelIdx) = str2double(parts(5));
    initialValues(channelIdx) = str2double(parts(6));
    checksums(channelIdx) = str2double(parts(7));
    descriptions(channelIdx) = strjoin(parts(9:end), " ");

    fprintf('\nChannel %d\n', channelIdx - 1);
    fprintf('  data file: %s\n', dataFiles(channelIdx));
    fprintf('  format: %.0f\n', formats(channelIdx));
    fprintf('  adc_gain: %.6g\n', gains(channelIdx));
    fprintf('  adc_resolution: %.0f\n', adcResolutions(channelIdx));
    fprintf('  adc_zero/baseline: %.0f\n', adcZeros(channelIdx));
    fprintf('  initial_value: %.0f\n', initialValues(channelIdx));
    fprintf('  checksum: %.0f\n', checksums(channelIdx));
    fprintf('  description: %s\n', descriptions(channelIdx));
end

if any(formats ~= 212)
    error('This inspection script expects both channels to use WFDB format 212.');
end

datFile = fullfile(recordFolder, dataFiles(1));
fid = fopen(datFile, 'r');
if fid < 0
    error('Could not open data file: %s', datFile);
end
cleanup = onCleanup(@() fclose(fid));

numTripletsToPrint = 100;
rawBytes = fread(fid, 3 * numTripletsToPrint, 'uint8=>double');
rawBytes = reshape(rawBytes, 3, []).';

fprintf('\nData file used: %s\n', datFile);
fprintf('\nFirst %d format-212 byte triplets and conversions:\n', numTripletsToPrint);
fprintf('triplet  bytes(hex)  ch0_u12 ch0_s12 ch0_phys    ch1_u12 ch1_s12 ch1_phys\n');

for tripletIdx = 1:size(rawBytes, 1)
    byte0 = rawBytes(tripletIdx, 1);
    byte1 = rawBytes(tripletIdx, 2);
    byte2 = rawBytes(tripletIdx, 3);

    ch0Unsigned = byte0 + 256 * bitand(byte1, 15);
    ch1Unsigned = byte2 + 256 * bitshift(byte1, -4);

    ch0Signed = twos_complement_12(ch0Unsigned);
    ch1Signed = twos_complement_12(ch1Unsigned);

    ch0Physical = (ch0Signed - adcZeros(1)) / gains(1);
    ch1Physical = (ch1Signed - adcZeros(2)) / gains(2);

    fprintf('%7d  %02X %02X %02X   %6d %7d %9.5f   %6d %7d %9.5f\n', ...
        tripletIdx - 1, byte0, byte1, byte2, ...
        ch0Unsigned, ch0Signed, ch0Physical, ...
        ch1Unsigned, ch1Signed, ch1Physical);
end

function signedValue = twos_complement_12(unsignedValue)
signedValue = unsignedValue;
if signedValue >= 2048
    signedValue = signedValue - 4096;
end
end
