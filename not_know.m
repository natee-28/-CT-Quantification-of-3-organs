clear; clc;

% โหลดหน้ากากทั้งสองตัวมาเช็กพิกัดพิกเซล
tsMask     = niftiread('F:\knomjeen_\File_non_contrast_nii\P001_Ser5_NonContrast_Standard_output_highres\vertebrae_L1.nii.gz');
skellyMask = niftiread('F:\knomjeen_\File_non_contrast_nii\P001_Ser5_NonContrast_Standard_output_highres\P001_Skelly_Output\P001_Ser5_NonContrast_Stand_medium_postprocessed_subseg_postprocessed.nii.gz');

% 1. หาตำแหน่งพิกเซลทั้งหมดที่เป็นกระดูก L1 ใน TotalSegmentator
[tsX, tsY, tsZ] = ind2sub(size(tsMask), find(tsMask > 0));

% 2. หาตำแหน่งพิกเซลที่เป็น Trabecular L1 (Label 21) ใน Skellytour
[skX, skY, skZ] = ind2sub(size(skellyMask), find(skellyMask == 21));

fprintf('=== ผลตรวจสอบพิกัด Matrix (QC Check) ===\n');
if ~isempty(tsX)
    fprintf('TotalSegmentator L1 อยู่ในช่วงแกน X: [%d ถึง %d] | Y: [%d ถึง %d] | Z: [%d ถึง %d]\n', ...
            min(tsX), max(tsX), min(tsY), max(tsY), min(tsZ), max(tsZ));
else
    fprintf('TotalSegmentator L1: ว่างเปล่า หาไม่เจอ\n');
end

if ~isempty(skX)
    fprintf('Skellytour Trabecular L1 อยู่ในช่วงแกน X: [%d ถึง %d] | Y: [%d ถึง %d] | Z: [%d ถึง %d]\n', ...
            min(skX), max(skX), min(skY), max(skY), min(skZ), max(skZ));
else
    fprintf('Skellytour Trabecular L1 (Label 21): ว่างเปล่า หาไม่เจอในไฟล์นี้\n');
end
