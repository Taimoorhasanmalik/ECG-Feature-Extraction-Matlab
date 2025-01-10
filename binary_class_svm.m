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
start_count = 1;
end_count = 1;
count = 1;
VFL_R_peak_ind = []; % Initialize to store R peak indexes
VFL_Q_peak_ind = []; % Initialize to store Q peak indexes
VFL_T_peak_ind = []; % Initialize to store T peak indexes
VFL_S_peak_ind = [];

N_R_peak_ind = []; % Initialize to store R peak indexes
N_Q_peak_ind = []; % Initialize to store Q peak indexes
N_T_peak_ind = []; % Initialize to store T peak indexes
N_S_peak_ind = [];
while count <= length(comments)
    rhythm = cell2mat(comments(count));
    
    % Check if rhythm matches '(VFL'
    if (length(rhythm) == 4) && all(rhythm == '(VFL')
        start_count = ann(count);
        
        % Find the end of the VFL rhythm
        while (count <= length(comments)) && ...
              (length(cell2mat(comments(count))) == 4) && ...
              all(cell2mat(comments(count)) == '(VFL')
            count = count + 1;
        end
        
        end_count = ann(count); % Mark the end of VFL section
        
        % Get R peak indices within the VFL section
        VFL_R_peak_ind = [VFL_R_peak_ind, R_peaks_ind((R_peaks_ind > start_count) & (R_peaks_ind < end_count))];
        VFL_Q_peak_ind = [VFL_Q_peak_ind, Q_peaks_ind((Q_peaks_ind > start_count) & (Q_peaks_ind < end_count))];
        VFL_T_peak_ind = [VFL_T_peak_ind, T_peaks_ind((T_peaks_ind > start_count) & (T_peaks_ind < end_count))];
        VFL_S_peak_ind = [VFL_S_peak_ind, S_peaks_ind((S_peaks_ind > start_count) & (S_peaks_ind < end_count))];
    
    else 
        if (length(rhythm) == 2) && all(rhythm == '(N')
        start_count = ann(count);
        
        % Find the end of the VFL rhythm
        while (count <= length(comments)) && ...
              (length(cell2mat(comments(count))) == 2) && ...
              all(cell2mat(comments(count)) == '(N')
            count = count + 1;
        end
        
        end_count = ann(count); % Mark the end of VFL section
        
        % Get R peak indices within the VFL section
        N_R_peak_ind = [N_R_peak_ind, R_peaks_ind((R_peaks_ind > start_count) & (R_peaks_ind < end_count))];
        N_Q_peak_ind = [N_Q_peak_ind, Q_peaks_ind((Q_peaks_ind > start_count) & (Q_peaks_ind < end_count))];
        N_T_peak_ind = [N_T_peak_ind, T_peaks_ind((T_peaks_ind > start_count) & (T_peaks_ind < end_count))];
        N_S_peak_ind = [N_S_peak_ind, S_peaks_ind((S_peaks_ind > start_count) & (S_peaks_ind < end_count))];
        else count = count + 1; % Move to the next comment
    end
    end
   

end
N_RR_int= calc_rr (N_R_peak_ind, Fs);
VFL_RR_int = calc_rr (VFL_R_peak_ind,Fs);
N_QS_int= calc_qs (N_Q_peak_ind,N_S_peak_ind, Fs);
VFL_QS_int = calc_qs (VFL_Q_peak_ind,VFL_S_peak_ind,Fs);


%%
gscatter ([ecg(VFL_R_peak_ind); ecg(N_R_peak_ind)],[ecg(VFL_Q_peak_ind);ecg(N_Q_peak_ind)], y);
classes=unique(y);
ms=length(classes);
SVMModels=cell(ms,1);
for j = 1:numel(classes)
    indx= y ==classes(j); % Create binary classes for each classifier
    SVMModels{j}=fitcsvm(x,indx,'ClassNames',[false true],'Standardize',true,...
        'KernelFunction','polynomial');
end


%%

e=min(x(:,1)):500:max(x(:,1));
f=min(x(:,2)):500:max(x(:,2));
[x1 x2]=meshgrid(e,f);
X=[x1(:) x2(:)];
N=size(X,1);
Scores=zeros(N,numel(classes));
for j=1:numel(classes)
    [~,score]=predict(SVMModels{j},x);
    Scores(1:length(score),j)=score(:,2); % Second column contains positive-class scores
end
[~,maxScore]=max(Scores,[],2);
figure
gscatter(x1(:),x2(:),maxScore);
hold on;
gscatter(x(:,1),x(:,2),y,'rgb','.');

axis tight
hold off


%% Feature making
x = [[VFL_R_peak_ind N_R_peak_ind]' , [VFL_Q_peak_ind N_Q_peak_ind]'... 
    , [VFL_S_peak_ind N_S_peak_ind]' , [VFL_T_peak_ind N_T_peak_ind]'...
    [VFL_RR_int N_RR_int]' [VFL_QS_int N_QS_int]'];


y  = (1:length(x));
y (1: length(VFL_T_peak_ind)) = 1;
y (length(VFL_T_peak_ind):end) = 2;

%%
count =1;
my_classes = ['N' , 'VFL'];
% map =containers.Map(ann,comments);
while count<length(ann)
    if (type(count) == '+')
        rhythm = cell2mat(comments(count));
        if ((length(rhythm) == 4) && all(rhythm == '(VFL'))
            ann(count)
        end
        if ((length(rhythm) == 2) && all(rhythm == '(N'))
            %count
        end
    end
    count = count +1;
end
