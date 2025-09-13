ECG Feature Extraction and Classification Project

This project processes ECG signals to detect arrhythmias using feature extraction and machine learning.

Project Structure:
1. databases/ - Contains ECG signal files (.hea and .dat files)
2. train_X.m - Main training script that:
   - Trains the model for X class
   - Reads ECG signals
   - Extracts features using Pan-Tompkins algorithm
   - Trains SVM model using 5-fold cross-validation
   - Saves trained model as 'X_model.mat'

3. inference_X.m - Testing script that:
   - Loads the trained 'X' model
   - Processes test data
   - Evaluates model performance
   - Shows confusion matrix and metrics

How to Use:
1. Place your ECG signal files in the 'databases' folder
2. Run train_X.m to train the model of your required class
3. Run inference_X.m to test the model

Required MATLAB Toolboxes:
- Signal Processing Toolbox
- Statistics and Machine Learning Toolbox
- WFDB Toolbox (for reading ECG files)

Note: Make sure all required toolboxes are installed before running the scripts.

