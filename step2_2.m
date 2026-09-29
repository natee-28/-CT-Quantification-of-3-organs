%% ========================================================================
%% Step 2 (Part 2): 8 cm Physical Distance Crop Calculator (Anti-Pitch Shift)
%% Uses True Coordinates (mm) instead of Slice Counting
%% ========================================================================
clear; clc;

% --- 1. โหลดตารางและตั้งค่าโฟลเดอร์ ---
[excelFile, excelPath] = uigetfile('*.xlsx', 'เลือกตาราง Excel ที่หมอปักหมุด L1_Z เสร็จแล้ว');
if excelFile == 0, return; end
masterLog = readtable(fullfile(excelPath, excelFile));

processFol = uigetdir('', 'เลือกโฟลเดอร์ที่มีไฟล์ภาพ .nii.gz (Process_KJ)');
if processFol == 0, return; end

outputAACFol = fullfile(processFol, 'AAC_Volume_8cm');
if ~exist(outputAACFol, 'dir'), mkdir(outputAACFol); end

selectedRows = find(contains(masterLog.ClassificationStatus, 'SELECTED') & ~isnan(masterLog.L1_Z));
fprintf('กำลังเริ่มคำนวณระยะทางกายภาพ 8 cm จริงจากพิกัดอวกาศแพทย์...\n');

%% --- 2. ลูปประมวลผลรายคนคัดแยกค่าระยะ Pitch รายเคส ---
for idx = 1:numel(selectedRows)
    row = selectedRows(idx);
    pFolderID = masterLog.PatientFolderID{row};
    sNum = masterLog.SeriesNumber(row);
    doctor_L1_slice = masterLog.L1_Z(row); % ดึงเลขสไลด์ที่หมอคลิกไว้
    
    % ค้นหาไฟล์ภาพ .nii.gz ที่สัมพันธ์กัน
    filePattern = fullfile(processFol, sprintf('%s_Ser%d_NonContrast_*.nii.gz', pFolderID, sNum));
    targetFileStruct = dir(filePattern);
    if isempty(targetFileStruct), continue; end
    
    % อ่านภาพ NIfTI และสกัดหัวไฟล์ Metadata
    currentFile = fullfile(targetFileStruct(1).folder, targetFileStruct(1).name);
    I = niftiread(currentFile);
    info = niftiinfo(currentFile);
    
    % ดึงรหัสข้อมูลการสไลด์เตียงรายแผ่นจริง (แกะจาก sMeta ที่เราดักจับไว้)
    % สำหรับ NIfTI นามสกุลระยะห่างแท้จริงเก็บใน PixelDimensions
    dz = info.PixelDimensions(3); 
    totalSlices = size(I, 3);
    
    % ---------------------------------------------------------------------
    % 🔥 [หัวใจหลักแก้ปัญหา Pitch] คำนวณระยะทางจากระดับ L1 ลงมา 80 mm ในใจคอมพิวเตอร์
    % ---------------------------------------------------------------------
    % แปลงระยะฟิสิกส์ 80 mm ให้เป็นจำนวนแผ่นภาพแปรผันตามระยะ Pitch ของคนนั้น
    numSlicesFor8cm = round(80 / dz);
    
    % คำนวณหาแผ่นสิ้นสุด (นับลงมาทางทิศท้ายลำตัว Caudal)
    end_slice = doctor_L1_slice - numSlicesFor8cm + 1;
    
    % ตรวจสอบความปลอดภัยไม่ให้ดัชนีแผ่นติดลบหลุดขอบล่างภาพ
    if end_slice < 1
        end_slice = 1;
        warning('  เคส %s: โปรโตคอลสแกนภาพมาสั้นกว่าระยะ 8 cm ระบบจะตัดเท่าที่มีถึงแผ่นล่างสุด', pFolderID);
    end
    
    % ทำการหั่นโครงสร้างภาพ 3D ดึงเฉพาะอุโมงค์ 8 cm ออกมา
    I_8cm = I(:, :, end_slice:doctor_L1_slice);
    
    % ปรับขนาด ImageSize แกน Z ในข้อมูลหัวไฟล์ตัวใหม่ให้สอดคล้องกัน
    info_8cm = info;
    info_8cm.ImageSize(3) = size(I_8cm, 3);
    
    % --- 3. บันทึกก้อนเนื้อภาพสเกลแม่นยำ 8 cm สำหรับนำไปสกัดเส้นเลือดใหญ่ ---
    outputFilename = fullfile(outputAACFol, sprintf('%s_Ser%d_Physical_8cm.nii.gz', pFolderID, sNum));
    try
        niftiwrite(single(I_8cm), outputFilename, info_8cm, 'Compressed', true);
    catch
        niftiwrite(single(I_8cm), outputFilename);
    end
    
    fprintf('  [Done] เคส %s: โปรโตคอล Pitch (dz) = %.2f mm -> หั่นสไลด์แผ่นที่ %d ถึง %d (ใช้จริง %d แผ่น)\n', ...
        pFolderID, dz, end_slice, doctor_L1_slice, size(I_8cm, 3));
end

disp('--- 🏁 ระบบหั่นระยะฟิสิกส์ 8 cm ป้องกันปัญหาความแปรผันของโปรโตคอลเสร็จสมบูรณ์! ---');
