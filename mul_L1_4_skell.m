clear; clc; close all;

%% 1. กำหนดตำแหน่งไฟล์ (Paths)
baseDir      = 'F:\knomjeen_\File_non_contrast_nii\P001_Ser5_NonContrast_Standard_output_highres\';
skellyDir    = fullfile(baseDir, 'P001_Skelly_Output');

% ไฟล์ภาพ CT ดิบ
ctFile       = 'F:\knomjeen_\File_non_contrast_nii\P001_Ser5_NonContrast_Standard.nii';

% ไฟล์หน้ากากก้อนรวมจาก Skellytour
skellyFile   = fullfile(skellyDir, 'P001_Ser5_NonContrast_Stand_medium_postprocessed_subseg_postprocessed.nii.gz');

% โหลดภาพ CT ดิบ และ หน้ากาก Skelly
CT = double(niftiread(ctFile));
skellyMask = niftiread(skellyFile);

%% 2. เริ่มขั้นตอนลูปคูณหน้ากากแยกรายข้อ (L1 - L4)
levelNames = {'L1', 'L2', 'L3', 'L4'};

% เลข Label สำหรับ Trabecular ของ L1, L2, L3, L4 จาก Skellytour
% (L1=21, L2=23, L3=25, L4=27)
skellyTrabecularLabels = [2,2,2,2]; 

figure('Name', 'Trabecular HU Distribution Analysis', 'Position', [100, 100, 1000, 700]);

for i = 1:4
    currentLevel = levelNames{i};
    
    % A. ดึงไฟล์หน้ากากเฉพาะข้อจาก TotalSegmentator (ค่าจะเป็น 1 ในส่วนที่เป็นกระดูกข้อนั้น)
    tsFile = fullfile(baseDir, sprintf('vertebrae_%s.nii.gz', currentLevel));
    if ~exist(tsFile, 'file')
        warning('ไม่พบไฟล์หน้ากาก TotalSegmentator ของ %s', currentLevel);
        continue;
    end
    tsMask = niftiread(tsFile);
    
    % B. ดึงหน้ากากเฉพาะ Trabecular Compartment จาก Skellytour (แปลงเป็น Binary Mask: 0 หรือ 1)
    skellyTrabMask = (skellyMask == skellyTrabecularLabels(i));
    
    % C. [ขั้นตอนสำคัญ] นำหน้ากากทั้งสองมาคูณกันทางคณิตศาสตร์ 
    % ผลลัพธ์จะเป็น 1 เฉพาะพิกเซลที่เป็นทั้ง "ข้อกระดูกนั้น" และเป็น "Trabecular" เท่านั้น
    finalTrabMask = double(tsMask) .* double(skellyTrabMask);
    
    % D. สกัดค่า HU ออกมาจากภาพ CT ดิบตามหน้ากากที่คูณเสร็จแล้ว
    trabecularHU = CT(finalTrabMask > 0);
    
    %% 3. คำนวณสถิติและแสดงผลลัพธ์ (Display Results)
    if ~isempty(trabecularHU)
        meanHU = mean(trabecularHU);
        sdHU   = std(trabecularHU);
        
        fprintf('ระดับ [%s] (คูณหน้ากากแล้ว): Mean = %.2f HU | SD = %.2f HU | จำนวน Voxel = %d\n', ...
                currentLevel, meanHU, sdHU, length(trabecularHU));
            
        % พล็อตแสดงผลกราฟ Histogram เพื่อเช็ก Pattern สถิติของกระดูกเนื้อใน
        subplot(2, 2, i);
        histogram(trabecularHU, 'BinWidth', 5, 'FaceColor', [0.2 0.6 0.8], 'EdgeColor', 'none');
        grid on;
        title(sprintf('Trabecular Bone: %s', currentLevel));
        xlabel('Hounsfield Units (HU)');
        ylabel('Voxel Count');
        xline(meanHU, 'r--', sprintf('Mean: %.1f', meanHU), 'LineWidth', 1.5, 'LabelVerticalAlignment', 'top');
    else
        fprintf('ระดับ [%s]: คูณหน้ากากแล้วไม่พบพื้นที่พิกเซลซ้อนทับกัน\n', currentLevel);
    end
end
