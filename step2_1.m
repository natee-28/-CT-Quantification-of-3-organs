%% ========================================================================
%% Step 2: Interactive Sagittal Spine Labeling Tool (Semi-Automated)
%% Compliant with PDPA & Vertebral Bone QC Protocol [Section 4]
%% ========================================================================
clear; clc; close all;

% --- 1. โหลดมาสเตอร์ล็อกแผ่นเดิม ---
[excelFile, excelPath] = uigetfile('*.xlsx', 'เลือกไฟล์ Excel DICOM_Master_Log_Batch');
if excelFile == 0, return; end
masterLog = readtable(fullfile(excelPath, excelFile));

processFol = uigetdir('', 'เลือกโฟลเดอร์ที่มีไฟล์ภาพ .nii.gz (Process_KJ)');
if processFol == 0, return; end

% เพิ่มคอลัมน์เก็บพิกัดแกน Z ของ L1-L4 ในตาราง (ถ้ายังไม่มี)
levels = {'L1_Z', 'L2_Z', 'L3_Z', 'L4_Z'};
for i = 1:numel(levels)
    if ~ismember(levels{i}, masterLog.Properties.VariableNames)
        masterLog.(levels{i}) = nan(height(masterLog), 1);
    end
end

% กรองเฉพาะแถวที่เป็นภาพดิบที่เราเลือกไว้
selectedIdx = find(contains(masterLog.ClassificationStatus, 'SELECTED'));

fprintf('--- ยินดีต้อนรับสู่โปรแกรมปักหมุดกระดูกสันหลัง L1-L4 ---\n');
fprintf('กติกา: โปรแกรมจะแสดงภาพ Sagittal ให้กดคลิกตรงกลางเนื้อกระดูกเรียงลำดับจาก L1 -> L2 -> L3 -> L4\n\n');

%% --- 2. วนลูปเปิดภาพให้หมอจิ้มรายเคส ---
for idx = 1:numel(selectedIdx)
    row = selectedIdx(idx);
    pFolderID = masterLog.PatientFolderID{row};
    sNum = masterLog.SeriesNumber(row);
    
    % ค้นหาไฟล์ภาพ .nii.gz
    filePattern = fullfile(processFol, sprintf('%s_Ser%d_NonContrast_*.nii.gz', pFolderID, sNum));
    targetFileStruct = dir(filePattern);
    if isempty(targetFileStruct), continue; end
    
    % อ่านภาพ NIfTI
    I = niftiread(fullfile(targetFileStruct(1).folder, targetFileStruct(1).name));
    
    % --- 3. สร้าง Sagittal Projection (ฉายภาพด้านข้างแนวกลางตัว) ---
    % หาจุดศูนย์กลางแกน X (ซ้าย-ขวา) เพื่อดึงระนาบตัดกึ่งกลางกระดูกสันหลังพอดี
    midX = round(size(I, 1) / 2);
    sagittal_view = squeeze(I(midX, :, :))'; % พลิกแกนให้หัวอยู่ด้านบน
    
    % --- 4. แสดงหน้าจอ Interactive GUI ให้หมอคลิก ---
    hFig = figure('Name', sprintf('Case: %s (ซีรีส์ %d) - ปักหมุด L1 ถึง L4', pFolderID, sNum), ...
                  'NumberTitle', 'off', 'Position', [100, 100, 800, 800]);
    
    % แสดงภาพปรับแต่ง Contrast ให้เห็นเนื้อกระดูกชัดเจน (Bone Window)
    imagesc(sagittal_view, [100, 700]); 
    colormap bone;
    axis image;
    set(gca, 'YDir', 'normal'); % ให้กระดูกเรียงจากหัวลงท้ายตามธรรมชาติ
    hold on;
    
    % ลูปรับการคลิก 4 ครั้งเรียงตามข้อ L1 -> L4
    z_coords = zeros(1, 4);
    for lvl = 1:4
        title(sprintf('🔴 เคสที่ %d/%d [%s]: กรุณาคลิกตรงกลางกระดูกข้อ L%d', ...
            idx, numel(selectedIdx), pFolderID, lvl), 'Color', 'r', 'FontSize', 12);
        
        % รอรับการกดคลิกเมาส์บนรูปภาพ
        [~, z_click] = ginput(1);
        
        % แปลงพิกัดที่คลิกกลับไปเป็นเลขแผ่น Slice แกน Z จริง
        z_slice = round(z_click);
        z_coords(lvl) = z_slice;
        
        % วาดจุดมาร์กสีเขียวบนจอทันทีเพื่อให้หมอเช็กความแม่นยำ
        plot(size(I, 2)/2, z_slice, 'g.', 'MarkerSize', 20);
        text(size(I, 2)/2 + 10, z_slice, sprintf('L%d', lvl), 'Color', 'g', 'FontWeight', 'bold');
    end
    
    % บันทึกพิกัดแกน Z ลงตาราง Master Table แยกรายข้อ
    masterLog.L1_Z(row) = z_coords(1);
    masterLog.L2_Z(row) = z_coords(2);
    masterLog.L3_Z(row) = z_coords(3);
    masterLog.L4_Z(row) = z_coords(4);
    
    close(hFig); % ปิดหน้าต่างเพื่อเตรียมเปิดเคสถัดไป
    
    % เซฟบันทึก Excel ทุกครั้งที่กดเสร็จ 1 เคส (ป้องกันไฟดับแล้วข้อมูลหาย)
    writetable(masterLog, fullfile(excelPath, excelFile));
end

disp('--- 🎉 บันทึกพิกัดกระดูกมาสเตอร์ L1-L4 ลงตารางเสร็จสมบูรณ์! ---');
