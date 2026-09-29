clear; clc; close all;

%% 1. กำหนดตำแหน่งไฟล์สำหรับเคส P001 (ADMIN Machine)
baseDir    = 'F:\knomjeen_\File_non_contrast_nii1\P020_Ser4_NonContrast_Standard_output_highres\';
ctFile     = 'F:\knomjeen_\File_non_contrast_nii1\P020_Ser4_NonContrast_Standard.nii';
skellyFile = fullfile(baseDir, 'P020_Skelly_Output', 'P020_Ser4_NonContrast_Stand_medium_postprocessed_subseg_postprocessed.nii.gz');
tsL1File   = fullfile(baseDir, 'vertebrae_L2.nii.gz');

%% 2. โหลดข้อมูลภาพและหน้ากากเข้าสู่หน่วยความจำ
CT         = double(niftiread(ctFile));
skellyMask = niftiread(skellyFile);
tsL1Mask   = niftiread(tsL1File);

%% 3. [แก้ไขจุดนี้] เปลี่ยนมาสกัดเลข 1 สำหรับ Trabecular เนื้อในตัวจริง!
skellyTrabMask = (skellyMask == 1); 
finalTrabMask  = double(tsL1Mask) .* double(skellyTrabMask); % คูณล็อกพิกัด

%% 4. หาตำแหน่ง Slice กึ่งกลางของข้อ L1 ในแกน Z เพื่อใช้พล็อตภาพ
[~, ~, zIndices] = ind2sub(size(tsL1Mask), find(tsL1Mask > 0));
midSlice = round((min(zIndices) + max(zIndices)) / 2);

%% 5. สั่งวาดรูปภาพเปรียบเทียบ (Visualization)
figure('Name', 'MATLAB Mask Multiplication - Corrected Trabecular (Label 1)', 'Position', [100, 200, 1100, 350]);

% --- หน้าต่างที่ 1: ภาพ CT ดิบต้นฉบับตรงข้อ L1 ---
subplot(1, 3, 1);
imagesc(CT(:, :, midSlice));
colormap(gca, 'gray'); axis image; axis off;
caxis([-100, 600]);
title(sprintf('1. Original CT (Slice %d)', midSlice));

% --- หน้าต่างที่ 2: หน้ากากเนื้อในตัวจริง (Label 1) จาก Skellytour ---
subplot(1, 3, 2);
imagesc(skellyTrabMask(:, :, midSlice));
colormap(gca, 'parula'); axis image; axis off;
title('2. Corrected Skellytour Trabecular');

% --- หน้าต่างที่ 3: ผลลัพธ์การคูณภาพ (ถมสีแดงกลางกระดูกข้อ L1) ---
subplot(1, 3, 3);
imshow(mat2gray(CT(:, :, midSlice), [-100, 600])); 
hold on;

redMask = cat(3, ones(size(finalTrabMask(:, :, midSlice))), ...
                 zeros(size(finalTrabMask(:, :, midSlice))), ...
                 zeros(size(finalTrabMask(:, :, midSlice))));
h = imshow(redMask);
set(h, 'AlphaData', finalTrabMask(:, :, midSlice) * 0.5); % โปร่งแสง 50%
hold off;
axis image; axis off;
title('3. True Multiplied Mask (L2 Trabecular)');

fprintf('=== แสดงผลรูปภาพที่แก้ไขเรียบร้อยแล้วบน Sliceที่ %d ===\n', midSlice);
