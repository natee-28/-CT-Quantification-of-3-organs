%% ========================================================================
%% LEAN PIPELINE WEEK 1: Ultimate Master Filter V4.1 (Syntax Loop Closed)
%% Multi-Size Frame Incompatibility Fixed | Loop Block End-Match Verified
%% ========================================================================
clear; clc;

% --- 1. ตั้งค่าโฟลเดอร์ใช้งาน ---
mainFol = uigetdir('', '1. เลือกโฟลเดอร์หลักที่มีกลุ่มคนไข้ (เช่น เซ็ต 100 คน)');
if mainFol == 0, return; end

outputFol = uigetdir('', '2. เลือกหรือสร้างโฟลเดอร์ปลายทาง (Process_KJ)');
if outputFol == 0, return; end
if ~exist(outputFol, 'dir'), mkdir(outputFol); end

fprintf('กำลังสแกนโครงสร้างไฟล์ DICOM ในเซ็ตนี้... (กรุณารอสักครู่)\n');
allFiles = dir(fullfile(mainFol, '**', '*'));
validIdx = ~[allFiles.isdir] & (startsWith({allFiles.name}, '0') | startsWith({allFiles.name}, 'I'));
files = allFiles(validIdx);

if isempty(files)
    error('ไม่พบไฟล์ DICOM ที่เข้าเงื่อนไขในโฟลเดอร์ที่เลือก');
end

%% --- 2. สกัด Metadata ของ Series (Single-thread เน้นเสถียรภาพถาวร) ---
numTotalFiles = numel(files);
fprintf('ตรวจพบไฟล์ดิบ %d ไฟล์ กำลังสแกนหัวไฟล์...\n', numTotalFiles);

metaCell = cell(numTotalFiles, 1);
seriesUIDs = cell(numTotalFiles, 1);
patientFolderIDs = cell(numTotalFiles, 1);

mainFolParts = strsplit(mainFol, filesep);

for i = 1:numTotalFiles
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
    
    if rem(i, 5000) == 0
        fprintf('  [Batch Log] สแกนผ่านหัวไฟล์แล้ว %d จาก %d ไฟล์...\n', i, numTotalFiles);
    end
end

validMeta = ~cellfun(@isempty, metaCell);
files = files(validMeta); metaCell = metaCell(validMeta);
seriesUIDs = seriesUIDs(validMeta); patientFolderIDs = patientFolderIDs(validMeta);

[uniqueSeries, ~, groupIdx] = unique(seriesUIDs);
numSeries = numel(uniqueSeries);

logData = table();

%% --- 3. คัดกรองขั้นเด็ดขาด (ตรวจสอบ END ของลูปและเงื่อนไขครบถ้วน) ---
fprintf('พบทั้งหมด %d Series กำลังเข้าสู่การวิเคราะห์พารามิเตอร์เทคนิค...\n', numSeries);

for s = 1:numSeries
    currIdx = (groupIdx == s);
    sFiles = files(currIdx);
    sMetaCell = metaCell(currIdx); 
    
    representativeMeta = sMetaCell{1};
    pFolderID = patientFolderIDs{find(currIdx, 1)};
    sUID = uniqueSeries{s};
    
    sDesc = ''; if isfield(representativeMeta, 'SeriesDescription'), sDesc = lower(representativeMeta.SeriesDescription); end
    sNum = []; if isfield(representativeMeta, 'SeriesNumber'), sNum = representativeMeta.SeriesNumber; end
    sDate = ''; if isfield(representativeMeta, 'SeriesDate'), sDate = representativeMeta.SeriesDate; end
    manufact = ''; if isfield(representativeMeta, 'Manufacturer'), manufact = representativeMeta.Manufacturer; end
    model = ''; if isfield(representativeMeta, 'ManufacturerModelName'), model = representativeMeta.ManufacturerModelName; end
    kvp = []; if isfield(representativeMeta, 'KVP'), kvp = representativeMeta.KVP; end
    
    mas = []; 
    if isfield(representativeMeta, 'XRayTubeCurrent'), mas = representativeMeta.XRayTubeCurrent; end
    if isfield(representativeMeta, 'Exposure'), mas = representativeMeta.Exposure; end 
    
    thick = []; if isfield(representativeMeta, 'SliceThickness'), thick = representativeMeta.SliceThickness; end
    matrixSize = []; if isfield(representativeMeta, 'Rows'), matrixSize = [representativeMeta.Rows, representativeMeta.Columns]; end
    pxSpacing = []; if isfield(representativeMeta, 'PixelSpacing'), pxSpacing = representativeMeta.PixelSpacing'; end
    kernel = ''; if isfield(representativeMeta, 'ConvolutionKernel'), kernel = representativeMeta.ConvolutionKernel; end
    
    planeType = 'Unknown';
    if isfield(representativeMeta, 'ImageOrientationPatient')
        iop = representativeMeta.ImageOrientationPatient;
        normal = cross(iop(1:3), iop(4:6));
        [~, maxAxis] = max(abs(normal));
        if maxAxis == 3, planeType = 'Axial';
        elseif maxAxis == 2, planeType = 'Coronal';
        elseif maxAxis == 1, planeType = 'Sagittal';
        end
    end
    
    isTargetPlane = strcmp(planeType, 'Axial');
    if contains(sDesc, {'coronal', 'sagittal', 'cor', 'sag', 'scout', 'localizer'})
        isTargetPlane = false;
    end
    
    isNonContrast = true;
    contrastKeywords = {'post', 'art', 'ven', 'pv', 'delay', 'contrast', 'c+', ...
                        'monophasic', 'ce', 'phase', 'arterial', 'liver', 'bladder', ...
                        'mins', 'min', 'adrenal', 'mip', 'cta', 'v.phas', 'phas', ...
                        'lung', 'chest', 'screen save', 'report', 'vrt', 'transparent'};
                    
    for k = 1:numel(contrastKeywords)
        if contains(sDesc, contrastKeywords{k})
            isNonContrast = false;
            break;
        end
    end
    
    if isempty(pxSpacing)
        isNonContrast = false;
    end
    
    saveImageFlag = false;
    if isTargetPlane && isNonContrast
        status = 'SELECTED & EXPORTED (Axial Non-Contrast)';
        saveImageFlag = true; 
    elseif ~isTargetPlane
        status = 'Log Only (Rejected Plane / Scout)';
    elseif ~isNonContrast
        status = 'Log Only (Rejected Contrast / MIP / Non-Target Phase)';
    else
        status = 'Log Only (Not Target)';
    end
    
    I_size = []; spacing = [];
    
    if saveImageFlag
        iop = representativeMeta.ImageOrientationPatient;
        normal = cross(iop(1:3), iop(4:6));         
        
        positions = zeros(numel(sMetaCell), 1);
        for idx = 1:numel(sMetaCell)
            positions(idx) = dot(sMetaCell{idx}.ImagePositionPatient, normal);
        end
        
        [~, order] = sort(positions);
        sMetaCell = sMetaCell(order);
        sFiles = sFiles(order);
        
        targetRows = representativeMeta.Rows;
        targetCols = representativeMeta.Columns;
        
        I = zeros(targetRows, targetCols, numel(sMetaCell));
        
        for i = 1:numel(sMetaCell)
            imgRaw = double(dicomread(fullfile(sFiles(i).folder, sFiles(i).name)));
            [currentRows, currentCols] = size(imgRaw);
            
            if currentRows == targetRows && currentCols == targetCols
                I(:,:,i) = imgRaw;
            else
                paddedImg = ones(targetRows, targetCols) * min(imgRaw(:));
                rowStart = floor((targetRows - currentRows)/2) + 1;
                colStart = floor((targetCols - currentCols)/2) + 1;
                paddedImg(rowStart:rowStart+currentRows-1, colStart:colStart+currentCols-1) = imgRaw;
                I(:,:,i) = paddedImg;
                
                fprintf('  [Smart Padded] %s Ser%d แผ่น %d (%dx%d -> %dx%d)\n', ...
                    pFolderID, sNum, i, currentRows, currentCols, targetRows, targetCols);
            end
        end
        
        if isfield(representativeMeta, 'RescaleSlope')
            I = I .* representativeMeta.RescaleSlope + representativeMeta.RescaleIntercept;
        end
        I_size = size(I);
        
        try px = representativeMeta.PixelSpacing(1); catch, px = 1; end
        try py = representativeMeta.PixelSpacing(2); catch, py = 1; end
        try
            zLoc = zeros(numel(sMetaCell), 1);
            for idx = 1:numel(sMetaCell)
                zLoc(idx) = sMetaCell{idx}.ImagePositionPatient(3);
            end
            dz = median(abs(diff(zLoc)));
        catch
            try dz = representativeMeta.SliceThickness; catch, dz = 1; end
        end
        if isnan(dz) || dz == 0, dz = 1; end
        spacing = [px, py, dz];
        
        reconTag = 'Standard';
        if (~isempty(thick) && thick <= 1.5) || contains(sDesc, {'thin', '1mm', '1.25', '0.5'})
            reconTag = 'ThinSlice';
        end
        
        niiFilename = fullfile(outputFol, sprintf('%s_Ser%d_NonContrast_%s', pFolderID, sNum, reconTag));
        try
            niftiwrite(single(I), niiFilename, 'SpatialDimensions', spacing);
        catch
            niftiwrite(single(I), niiFilename); 
        end
    end % <-- ปิดบล็อก saveImageFlag
    
    sizeStr = 'N/A'; if ~isempty(I_size), sizeStr = sprintf('%dx%dx%d', I_size); end
    spacingStr = 'N/A'; if ~isempty(spacing), spacingStr = sprintf('[%.2f, %.2f, %.2f]', spacing); end
    matStr = 'N/A'; if ~isempty(matrixSize), matStr = sprintf('%dx%d', matrixSize); end
    
    newRow = table({pFolderID}, {sDate}, {sNum}, {sDesc}, {manufact}, {model}, ...
                   {kvp}, {mas}, {thick}, {kernel}, {matStr}, {spacingStr}, ...
                   {status}, {sUID}, ...
                   'VariableNames', {'PatientFolderID', 'CT_Date', 'SeriesNumber', 'SeriesDescription', ...
                                     'Manufacturer', 'ScannerModel', 'kVp', 'mAs_or_Current', ...
                                     'SliceThickness', 'ReconstructionKernel', 'MatrixSize', 'PixelSpacing', ...
                                     'ClassificationStatus', 'SeriesInstanceUID'});
    logData = [logData; newRow];
end % <-- ปิดบล็อกลูปฟังก์ชันหลักของ Series (s = 1:numSeries)

% เขียนมาสเตอร์ล็อกส่งต่อทีมแพทย์
excelFilename = fullfile(outputFol, 'DICOM_Master_Log_Batch_V4_1.xlsx');
writetable(logData, excelFilename);

fprintf('\n====================================================================\n');
fprintf(' 🎉 [แก้ไขสำเร็จ!] ระบบ Ultimate Master Filter V4.1 ปิดบล็อกคำสั่งสมบูรณ์\n');
fprintf(' โครงสร้างลูปปิดครบถ้วน ไร้อาการหลุดรอด ไหลลื่นข้ามคืนได้เลยครับ\n');
fprintf('====================================================================\n');
