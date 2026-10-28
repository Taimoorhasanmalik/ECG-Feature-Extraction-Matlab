function outputQ8 = stage2_fixed_filter_matlab(rawQ16)
% Exact fixed-point Stage 2 filter reference. Input: signed Q16.16 integers.
% Uses 128-bit integer fi arithmetic for products/sums, so Q2.29 coefficients
% and negative truncation match stage2_filter_q29.v without double rounding.

rawQ16 = int64(rawQ16(:));
modelPath = fullfile(fileparts(fileparts(fileparts(mfilename('fullpath')))), ...
    'stage2', 'deliverable', 'stage2_hardware_model.json');
model = jsondecode(fileread(modelPath));
sos = int64(round(double(model.filter.sos_with_gain_folded_in)*2^29));
dc = int64([535469054,-535469054,-534067196]);
arith = fimath('RoundingMethod','Floor','OverflowAction','Wrap', ...
    'ProductMode','SpecifyPrecision','ProductWordLength',128, ...
    'ProductFractionLength',0,'SumMode','SpecifyPrecision', ...
    'SumWordLength',128,'SumFractionLength',0);
type = numerictype(1,128,0);
dx1 = int64(0); dy1 = int64(0);
state = zeros(4,4,'int64'); % per SOS: x1,x2,y1,y2
outputQ8 = zeros(size(rawQ16),'int16');
for n = 1:numel(rawQ16)
    dsum = product(rawQ16(n),dc(1),type,arith) + ...
        product(dx1,dc(2),type,arith) - product(dy1,dc(3),type,arith);
    dy = wrap_int(shift_toward_zero(dsum,29),32);
    dx1 = rawQ16(n); dy1 = dy;
    dcQ8 = min(max(shift_toward_zero(fi(dy,type,arith),8),-8192),8191);
    x = bitshift(int64(dcQ8),21);
    for section = 1:4
        row = sos(section,:);
        sectionSum = product(x,row(1),type,arith) + ...
            product(state(section,1),row(2),type,arith) + ...
            product(state(section,2),row(3),type,arith) - ...
            product(state(section,3),row(5),type,arith) - ...
            product(state(section,4),row(6),type,arith);
        y = wrap_int(shift_toward_zero(sectionSum,29),40);
        state(section,:) = [x,state(section,1),y,state(section,3)];
        x = y;
    end
    outputQ8(n) = int16(min(max(shift_toward_zero(fi(x,type,arith),21),-8192),8191));
end

function out = wrap_int(value,bits)
out = int64(mod(double(value)+2^(bits-1),2^bits)-2^(bits-1));
end
end

function out = product(a,b,type,arith)
out = fi(a,type,arith)*fi(b,type,arith);
end

function out = shift_toward_zero(value,amount)
if value < 0
    out = -int64(bitsra(-value,amount));
else
    out = int64(bitsra(value,amount));
end
end
