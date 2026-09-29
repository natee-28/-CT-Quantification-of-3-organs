clear; clc; close all;

%% 1. Environment & Global Path Setup
baseDataDir     = 'F:\knomjeen_\File_non_contrast_nii1\';
anacondaBatPath = 'C:\Users\ADMIN\anaconda3\condabin\conda.bat';
excelFile       = 'CT_Adrenal_Research_Pilot_20Cases_QC_Final.xlsx';

% ระบบ Patch หลอกบั๊ก Windows สำหรับ Skellytour
patchPython = 'python -c "import os; os.uname = lambda: [''Windows'', ''localhost'']"';

%% 2. [แก้ข้อ 3] Dynamic Directory Scan (สแกนหาโฟลเดอร์ผู้ป่วยจริง ไม่ก๊องแก๊ง)
% วิ่งหาโฟลเดอร์ทั้งหมดที่ลงท้ายด้วย '_output_highres' ใน baseDataDir เพื่อดึง Patient ID จริง
dirInfo = dir(fullfile(baseDataDir, '*_output_highres'));
if isempty(dirInfo)
    error('ไม่พบโฟลเดอร์ผลลัพธ์ย่อยใน %s รบกวนตรวจสอบ Path', baseDataDir);
end

fprintf('=== [Start] ตรวจพบข้อมูลผู้ป่วยทั้งหมด %d เคสในระบบ ===\n', length(dirInfo));

%% 3. ลูปหลักสำหรับประมวลผลทีละเคส (End-to-End Automation)
for p = 1:length(dirInfo)
    % สกัดชื่อโฟลเดอร์ เช่น 'P001_Ser5_NonContrast_Standard_output_highres'
    targetDirName = dirInfo(p).name; 
    patientDir    = fullfile(baseDataDir, targetDirName);
    
    % [แก้ข้อ 3] ใช้ Regular Expression ดึง Patient ID ออกมาจากชื่อโฟลเดอร์โดยอัตโนมัติ
    tokens = regexp(targetDirName, '^(P\d+)', 'tokens');
    if isempty(tokens), continue; end
    currentPatient = tokens{1}{1}; % ได้ค่าเป็น 'P001', 'P002' ฯลฯ
    
    fprintf('\n==================================================\n');
    fprintf('▶ Processing [%s] (%d/%d)\n', currentPatient, p, length(dirInfo));
    
    %% 4. [แก้ข้อ 2] Dynamic File Search (หาไฟล์ภาพ CT ดิบ และหน้ากากแยกข้อ โดยไม่สนเลข Series)
    % สแกนหาไฟล์ภาพ CT ดิบตัวเต็มในโฟลเดอร์หลัก (ไฟล์ที่ไม่มีคำว่า output หรือ mask ในชื่อ)
    ctSearch = dir(fullfile(baseDataDir, [currentPatient, '*NonContrast*.nii*']));
    if isempty(ctSearch)
        ctSearch = dir(fullfile(baseDataDir, [currentPatient, '*plain*.nii*'])); % แผนสำรองถ้าชื่อไฟล์เป็นคำว่า plain
    end
    
    if isempty(ctSearch)
        warning('ไม่พบไฟล์ภาพ CT ดิบของเคส %s (ข้ามเคสนี้)', currentPatient);
        continue;
    end
    ctFile = fullfile(baseDataDir, ctSearch(1).name); % ได้ Path ไฟล์ CT ดิบตัวจริงของเคสนั้น
    
    %% 5. [แก้ข้อ 1] รันโมเดล Skellytour สดๆ ในลูป (ถ้ายังไม่มีผลลัพธ์)
    skellyOutDir = fullfile(patientDir, 'P001_Skelly_Output'); % โฟลเดอร์ปลายทาง
    if ~exist(skellyOutDir, 'dir'), mkdir(skellyOutDir); end
    
    % ตรวจสอบว่าเคยรัน Skellytour ของเคสนี้สำเร็จไปแล้วหรือยัง (ดูจากไฟล์ผลลัพธ์สุดท้าย)
    skellySearch = dir(fullfile(skellyOutDir, '*_subseg_postprocessed.nii.gz'));
    
    if isempty(skellySearch)
        fprintf(' -> ไม่พบผลลัพธ์เก่า เริ่มสั่งรัน Skellytour (AI) หลังบ้าน...\n');
        % ประกอบคำสั่งแบบสับสปีดเต็มพิกัด (--fast) รันสดผ่านระบบมัดรวมคำสั่งวิธีที่ 1
        cmd = sprintf('"%s" activate ts_env && %s && skellytour -i "%s" -o "%s" -m medium --fast --subseg', ...
                      anacondaBatPath, patchPython, ctFile, skellyOutDir);
        
        tic;
        [status, cmdout] = system(cmd);
        if status ~= 0
            warning('Skellytour ทำงานล้มเหลวในเคส %s: %s', currentPatient, cmdout);
            continue;
        end
        fprintf(' -> AI รันเสร็จสิ้น! ใช้เวลา: %.2f วินาที\n', toc);
        skellySearch = dir(fullfile(skellyOutDir, '*_subseg_postprocessed.nii.gz'));
    else
        fprintf(' -> พบผลลัพธ์ Skellytour เดิมในระบบ ข้ามขั้นตอน AI ไปยังสเต็ปคำนวณ...\n');
    end
    
    % โหลดไฟล์หน้ากากก้อนรวมของ Skellytour ที่เพิ่งรันเสร็จหรือมีอยู่เดิม
    skellyFile = fullfile(skellyOutDir, skellySearch(1).name);
    skellyMask = niftiread(skellyFile);
    CT         = double(niftiread(ctFile));
    %niiInfo    = niftiinfo(tsFile);
    
        % --- ลบหรือคอมเมนต์บรรทัดเดิมตรงนี้ทิ้งไปเลยครับ ---
    % niiInfo = niftiinfo(tsFile); <-- ลบออกได้เลยครับ!
    
    %% 6. ขั้นตอนการคูณหน้ากากแยกข้อ (Mask Multiplication) และเซฟไฟล์
    levelNames = {'L1', 'L2', 'L3', 'L4'};
    for i = 1:4
        currentLevel = levelNames{i};
        tsFile = fullfile(patientDir, sprintf('vertebrae_%s.nii.gz', currentLevel));
        
        if ~exist(tsFile, 'file'), continue; end
        tsMask = niftiread(tsFile);
        
        % คูณหน้ากากสกัดเอาเฉพาะพิกเซลเนื้อใน (Label 2)
        finalTrabMask = double(tsMask) .* double(skellyMask == 2);
        trabecularHU  = CT(finalTrabMask > 0);
        
        if ~isempty(trabecularHU)
            % ตั้งชื่อไฟล์ผลลัพธ์เฉพาะข้อในฝัน
            outMaskName = sprintf('%s_%s_trabecular.nii.gz', currentPatient, currentLevel);
            
            %% === [จุดที่ถูกต้อง] ดึงหัวไฟล์จากหน้ากาก TS ภายในลูปและสั่งเขียนไฟล์ ===
            niiInfo = niftiinfo(tsFile); 
            niftiwrite(uint8(finalTrabMask > 0), fullfile(patientDir, outMaskName), niiInfo, 'Compressed', true);
        end
    end
    fprintf(' -> บันทึกไฟล์หน้ากากแยกข้อ L1-L4 ของเคส %s เรียบร้อยครับ\n', currentPatient);
end

  
