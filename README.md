﻿# ECG-Feature-Extraction-Matlab
## 1. Pre-processing ##
The pre-processing part involves multiple steps, starting from 
### 1. Data Acquisition:###
In the data acquisition step we use the wfdb library of matlab to read through the databases and return the data and annotation arrays.
### 2. Feature Extraction: ###
Next, we use the available pantompkins function to extract all the available features using just the ecg data files.
### 3. Annotation of Features: ###
Using the annotations array. The respective features are divided into arrays based on the annotated arrhythmia. (Matlab classes were used to store the peaks with respect to the arrhythmia)
### 4. Calculation of RR and QS intervals: ###
After receiving all the required peaks from the data the respective RR and QS intervals are calculated for each arrhythmia.
## 2. Data Set Division: ##
After receiving the 2 arrays X_all and Y_all the data is then divided into training and testing data. With a ratio of 80:20 respectively.
## 3. SVM Model Training: ##
