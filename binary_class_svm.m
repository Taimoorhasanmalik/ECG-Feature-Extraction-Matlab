display('Reading samples ECG signal from MIT-BIH Arrhythmia Database')
[ecg,Fs,tm]=rdsamp('mitdbase/207',1);

display(['Reading and plotting annotations (human labels) of QRS complexes performend on the signals'])
[ann,type,subtype,chan,num,comments] =rdann('mitdbase/207','atr',1);
%%
[R_peaks_val, R_peaks_ind,Q_peaks_ind, Q_peaks_val,S_peaks_ind, S_peaks_val,T_peaks_ind, T_peaks_val, delay] = pan_tompkin(ecg, Fs);

%% RR_int
count = 1;
RR_int = [];
for i = R_peaks_ind
    count = count +1;
    if count >2
        RR_int = [RR_int , (i-temp_i)/Fs];
    end
    temp_i = i;

end
%% Calculating QS interval
i =1 ;
QS_int = [];
while i < length(S_peaks_ind)
    QS_int = [QS_int (S_peaks_ind(i)-Q_peaks_ind(i))/Fs];
    i = i+1;
end

%%
my_classes = [1 2];
count = 1;
VF_start = [];
VF_stop = [];
VF_beats = [];
N_beats = []

count =1;
while count<length(type)
    if type(count) == '['
        VF_start = [VF_start ann(count)];
    end
    if type(count) == ']'
        VF_stop = [VF_stop ann(count)];
    end
    if type(count) == '!'
        VF_beats = [VF_beats ann(count)];
    end
    if(type(count) == 'N')
        N_beats = [N_beats count];
    end
    count = count +1;
end
%%
%features = [R_peaks_ind, Q_peaks_ind, S_peaks_ind, T_peaks_ind, RR_int, QS_int];
count =1;
N_beats = []
while count<length(ann)
    if(type(count) == 'N')
        N_beats = [N_beats count];
    end
    count = count +1;
end


%% Using Comments
comments2 = comments;
count =1;
my_classes = ['N' , 'VFL'];
rhythm = comments(count);
while count<length(ann)
    if (type(count) == '+')
        rhythm = comments(count);
    end
    comments(count) = rhythm;

    count = count +1;
end


%%
count =1;
my_classes = ['N' , 'VFL'];
% map =containers.Map(ann,comments);
while count<length(ann)
    if (type(count) == '+')
        rhythm = cell2mat(comments(count));
        if ((length(rhythm) == 4) && all(rhythm == '(VFL'))
            count
        end
        if ((length(rhythm) == 2) && all(rhythm == '(N'))
            %count
        end
    end
    count = count +1;
end