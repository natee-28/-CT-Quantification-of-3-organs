%% ========================================================================
%% WEEK 1 PIPELINE: DICOM Filtering, Metadata Logging & Format Conversion (Plane Filtered)
%% ========================================================================
clear; clc;

% --- 1. ตั้งค่าโฟลเดอร์ใช้งาน ---
mainFol = uigetdir('', '1. เลือกโฟลเดอร์หลักที่มี P001-P303 (kanomjeen)');
if mainFol == 0, return; end

outputFol = uigetdir('', '2. เลือกหรือสร้างโฟลเดอร์ปลายทาง (Process_KJ)');
if outputFol == 0, return; end
if ~exist(outputFol, 'dir'), mkdir(outputFol); end

% ค้นหาไฟล์ทั้งหมดลึกเข้าไปในโฟลเดอร์ย่อย
fprintf('กำลังสแกนหาไฟล์ DICOM ทั้งหมดในระบบ... (อาจใช้เวลาครู่หนึ่ง)\n');
allFiles = dir(fullfile(mainFol, '**', '*'));
validIdx = ~[allFiles.isdir] & (startsWith({allFiles.name}, '0') | startsWith({allFiles.name}, 'I'));
files = allFiles(validIdx);

if isempty(files)
    error('ไม่พบไฟล์ DICOM ที่เข้าเงื่อนไขในโฟลเดอร์ที่เลือก');
end

%% --- 2. สกัด Metadata และดึงรหัสโฟลเดอร์ (PDPA Anonymization) ---
fprintf('ตรวจพบไฟล์ดิบ %d ไฟล์ กำลังอ่านข้อความหัวไฟล์ (Metadata)...\n', numel(files));

metaCell = cell(numel(files), 1);
seriesUIDs = cell(numel(files), 1);
patientFolderIDs = cell(numel(files), 1);

mainFolParts = strsplit(mainFol, filesep);

for i = 1:numel(files)
    try
        m = dicominfo(fullfile(files(i).folder, files(i).name));
        metaCell{i} = m;
        seriesUIDs{i} = m.SeriesInstanceUID;
        
        filePathParts = strsplit(files(i).folder, filesep);
        matchIdx = find(strcmp(filePathParts, mainFolParts{end}), 1);
        if ~isempty(matchIdx) && (matchIdx + 1 <= numel(filePathParts))
            patientFolderIDs{i} = filePathParts{matchIdx + 1};
        else
            patientFolderIDs{i} = 'UnknownPatient';
        end
    catch
        metaCell{i} = []; seriesUIDs{i} = ''; patientFolderIDs{i} = '';
    end
    
    if rem(i, 500) == 0
        fprintf('  อ่านไฟล์เสร็จสิ้นแล้ว %d จาก %d ไฟล์...\n', i, numel(files));
    end
end

% เคลียร์ค่าว่างออก
validMeta = ~cellfun(@isempty, metaCell);
files = files(validMeta); metaCell = metaCell(validMeta);
seriesUIDs = seriesUIDs(validMeta); patientFolderIDs = patientFolderIDs(validMeta);

[uniqueSeries, ~, groupIdx] = unique(seriesUIDs);
numSeries = numel(uniqueSeries);

logData = table();

%% --- 3. ประมวลผล คัดกรองภาพ และแปลงไฟล์ส่งออกตามชื่อรหัสโฟลเดอร์ ---
fprintf('พบทั้งหมด %d Series กำลังเข้าสู่กระบวนการคัดกรองและสกัดข้อมูล...\n', numSeries);

for s = 1:numSeries
    currIdx = (groupIdx == s);
    sMeta = [metaCell{currIdx}];
    sFiles = files(currIdx);
    
    pFolderID = patientFolderIDs{find(currIdx, 1)};
    sUID = uniqueSeries{s};
    
    sDesc = ''; if isfield(sMeta(1), 'SeriesDescription'), sDesc = lower(sMeta(1).SeriesDescription); end
    bPart = ''; if isfield(sMeta(1), 'BodyPartExamined'), bPart = upper(sMeta(1).BodyPartExamined); end
    sDate = ''; if isfield(sMeta(1), 'SeriesDate'), sDate = sMeta(1).SeriesDate; end
    
    % --- [ปรับปรุงใหม่] เช็กมิติระนาบภาพจากโครงสร้างทางคณิตศาสตร์อย่างละเอียด ---
    planeType = 'Unknown'; 
    if isfield(sMeta(1), 'ImageOrientationPatient')
        iop = sMeta(1).ImageOrientationPatient;
        normal = cross(iop(1:3), iop(4:6)); % เวกเตอร์แนวตั้งฉากกับแผ่นภาพ
        
        [~, maxAxis] = max(abs(normal));
        if maxAxis == 3
            planeType = 'Axial';
        elseif maxAxis == 2
            planeType = 'Coronal';
        elseif maxAxis == 1
            planeType = 'Sagittal';
        end
    end
    
    % --- เงื่อนไขกรองคีย์เวิร์ด (เพิ่มชุดดักจับระนาบภาษาเขียน) ---
    isNonContrast = true; 
    % เพิ่ม 'cor', 'sag' เข้าไปในคำสั่งบล็อกภาพ
    rejectKeywords = {'post', 'delay', 'art', 'ven', 'pv', 'contrast', 'c+', 'monophasic', 'cor', 'sag', 'scout'};
    for k = 1:numel(rejectKeywords)
        if contains(sDesc, rejectKeywords{k})
            isNonContrast = false;
            break;
        end
    end
    
    % --- กำหนดสถานะตามข้อมูลระนาบใหม่ ---
    status = 'Rejected';
    if strcmp(planeType, 'Axial') && isNonContrast
        status = 'SELECTED (Non-Contrast Axial)';
    elseif strcmp(planeType, 'Coronal')
        status = 'Rejected (Coronal Plane)';
    elseif strcmp(planeType, 'Sagittal')
        status = 'Rejected (Sagittal Plane)';
    elseif ~isNonContrast
        status = 'Rejected (Contrast or Non-Target Phase)';
    else
        status = 'Rejected (Invalid/Scout View)';
    end
    
    I_size = [];
    spacing = [];
    
    if strcmp(status, 'SELECTED (Non-Contrast Axial)')
        iop = sMeta(1).ImageOrientationPatient;
        normal = cross(iop(1:3), iop(4:6));         
        positions = arrayfun(@(m) dot(m.ImagePositionPatient, normal), sMeta);
        [~, order] = sort(positions);
        sMeta = sMeta(order); sFiles = sFiles(order);
        
        I = [];
        for i = 1:numel(sMeta)
            I(:,:,i) = double(dicomread(fullfile(sFiles(i).folder, sFiles(i).name)));
        end
        
        if isfield(sMeta(1), 'RescaleSlope')
            I = I .* sMeta(1).RescaleSlope + sMeta(1).RescaleIntercept;
        end
        I_size = size(I);
        
        try px = sMeta(1).PixelSpacing(1); catch, px = 1; end
        try py = sMeta(1).PixelSpacing(2); catch, py = 1; end
        try
            zLoc = cellfun(@(m) m.ImagePositionPatient(3), num2cell(sMeta));
            dz = median(abs(diff(zLoc)));
        catch
            try dz = sMeta(1).SliceThickness; catch, dz = 1; end
        end
        if isnan(dz) || dz == 0, dz = 1; end
        spacing = [px, py, dz];
        
        % EXPORT 1: .mat
        matFilename = fullfile(outputFol, sprintf('%s_NonContrast.mat', pFolderID));
        save(matFilename, 'I', 'spacing', 'pFolderID', 'sUID', '-v7.3');
        
        % EXPORT 2: .nii
        niiFilename = fullfile(outputFol, sprintf('%s_NonContrast.nii', pFolderID));
        try
            niftiwrite(single(I), niiFilename, 'SpatialDimensions', spacing);
        catch
            niftiwrite(single(I), niiFilename); 
        end
    end
    
    sizeStr = 'N/A'; if ~isempty(I_size), sizeStr = sprintf('%dx%dx%d', I_size); end
    spacingStr = 'N/A'; if ~isempty(spacing), spacingStr = sprintf('[%.2f, %.2f, %.2f]', spacing); end
    
    % --- บันทึกประวัติลงตารางสำหรับการเขียน Excel ---
    newRow = table({pFolderID}, {sUID}, {sDesc}, {bPart}, {sDate}, {sizeStr}, ...
                   {spacingStr}, {status}, ...
                   'VariableNames', {'PatientFolderID', 'SeriesInstanceUID', 'SeriesDescription', ...
                                     'BodyPartExamined', 'SeriesDate', 'VolumeSize', 'Spacing_mm', 'Status'});
    logData = [logData; newRow];
end

% --- 4. เขียนข้อมูลลงไฟล์ Excel มาสเตอร์คุมงาน ---
excelFilename = fullfile(outputFol, 'DICOM_Master_Log.xlsx');
writetable(logData, excelFilename);

fprintf('\n================================================================\n');
fprintf(' ดำเนินการสัปดาห์ที่ 1 สำเร็จเสร็จสิ้น! (ระบบคัดกรองระนาบ Cor/Sag เรียบร้อย)\n');
fprintf(' ข้อมูล Master Log ถูกบันทึกไปที่: %s\n', excelFilename);
fprintf(' ข้อมูลภาพนิรนามถูกจัดเก็บไว้ที่โฟลเดอร์: %s\n', outputFol);
fprintf('================================================================\n');
