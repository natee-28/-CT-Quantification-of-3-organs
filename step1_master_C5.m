%% ========================================================================
%% LEAN PIPELINE WEEK 1: Ultimate Master Filter V4.1-C5 (Non-contrast classifier refined)
%% Per-slice HU | DICOM spacing + RAS sform | NIfTI QC | Refined non-contrast selection
%% ========================================================================
clear; clc;
addpath('F:\knomjeen_');
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
    
    % --------------------------------------------------------------------
    % C5: Refined non-contrast classifier.
    % Keep the original contrast keyword list (including "ce") and add the
    % protocol labels observed in the first 20 cases (D-KUB, A-P, V-P).
    %
    % Important: the word "noncontrast" contains the substring "contrast".
    % Therefore, remove only the explicit NON-CONTRAST phrase from a temporary
    % copy before searching contrast keywords. This allows P005 "noncontrast"
    % to be selected, while descriptions such as "plain delayed" are still
    % rejected because "delayed" remains present.
    % --------------------------------------------------------------------
    isNonContrast = true;

    contrastKeywords = {'post', 'art', 'ven', 'pv', 'delay', 'contrast', 'c+', ...
                        'monophasic', 'ce', 'phase', 'arterial', 'liver', 'bladder', ...
                        'mins', 'min', 'adrenal', 'mip', 'cta', 'v.phas', 'phas', ...
                        'lung', 'chest', 'screen save', 'report', 'vrt', 'transparent', ...
                        'd-kub', 'a-p', 'v-p','d.kub','d-lay','d.'};

    NonContrastKeywords = {'plain', 'noncontrast', 'non contrast','pre'};

    % Detect an explicit non-contrast label for logging/decision support.
    hasExplicitNonContrast = false;
    for kk = 1:numel(NonContrastKeywords)
        if contains(sDesc, NonContrastKeywords{kk})
            hasExplicitNonContrast = true;
            break;
        end
    end

    % Prevent "noncontrast" itself from being falsely caught by "contrast".
    sDescForContrast = regexprep(sDesc, 'non\s*contrast', '');

    hasContrastKeyword = false;
    matchedContrastKeyword = '';
    for k = 1:numel(contrastKeywords)
        if contains(sDescForContrast, contrastKeywords{k})
            hasContrastKeyword = true;
            matchedContrastKeyword = contrastKeywords{k};
            break;
        end
    end

    % Hard reject has priority. Explicit plain/noncontrast is accepted only
    % when no contrast/protocol-exclusion keyword remains in the description.
    if hasContrastKeyword
        isNonContrast = false;
    elseif hasExplicitNonContrast
        isNonContrast = true;
    else
        % Keep the previous C4 behaviour for descriptions with no clear label.
        isNonContrast = true;
    end

    if isempty(pxSpacing)
        isNonContrast = false;
    end

    % C5: TotalSegmentator requires a true 3-D CT volume.
    % Reject single/very-short derived series early instead of letting
    % niftiwrite collapse the third dimension and stop the whole batch.
    numSlicesSeries = numel(sMetaCell);
    isVolumetricSeries = numSlicesSeries >= 3;
    
    saveImageFlag = false;
    if isTargetPlane && isNonContrast && isVolumetricSeries
        status = 'SELECTED & EXPORTED (Axial Non-Contrast)';
        saveImageFlag = true; 
    elseif ~isVolumetricSeries
        status = sprintf('Log Only (Rejected Non-volumetric: %d slices)', numSlicesSeries);
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

            % C1: Convert stored pixel values to HU per slice before stacking.
            % Default values follow the DICOM convention when rescale tags are absent.
            slope = 1;
            intercept = 0;
            if isfield(sMetaCell{i}, 'RescaleSlope') && ~isempty(sMetaCell{i}.RescaleSlope)
                slope = double(sMetaCell{i}.RescaleSlope);
            end
            if isfield(sMetaCell{i}, 'RescaleIntercept') && ~isempty(sMetaCell{i}.RescaleIntercept)
                intercept = double(sMetaCell{i}.RescaleIntercept);
            end
            imgHU = imgRaw .* slope + intercept;
            
            if currentRows == targetRows && currentCols == targetCols
                I(:,:,i) = imgHU;
            else
                % Pad in HU space so padded voxels do not get rescaled again.
                paddedImg = ones(targetRows, targetCols) * min(imgHU(:));
                rowStart = floor((targetRows - currentRows)/2) + 1;
                colStart = floor((targetCols - currentCols)/2) + 1;
                paddedImg(rowStart:rowStart+currentRows-1, colStart:colStart+currentCols-1) = imgHU;
                I(:,:,i) = paddedImg;
                
                fprintf('  [Smart Padded] %s Ser%d แผ่น %d (%dx%d -> %dx%d)\n', ...
                    pFolderID, sNum, i, currentRows, currentCols, targetRows, targetCols);
            end
        end

        % HU conversion is already performed per slice above.
        I_size = size(I);
        
        % C2: Use true DICOM voxel spacing. PixelSpacing(1) is row spacing,
        % PixelSpacing(2) is column spacing. Slice spacing is measured along
        % the slice-normal, which is more robust than using Z alone.
        try px = double(representativeMeta.PixelSpacing(1)); catch, px = 1; end
        try py = double(representativeMeta.PixelSpacing(2)); catch, py = 1; end
        try
            if numel(positions) > 1
                sortedPos = sort(positions);
                dz = median(abs(diff(sortedPos)));
            else
                dz = double(representativeMeta.SliceThickness);
            end
        catch
            try dz = double(representativeMeta.SliceThickness); catch, dz = 1; end
        end
        if ~isfinite(dz) || dz <= 0, dz = 1; end
        spacing = [px, py, dz];
        
        reconTag = 'Standard';
        if (~isempty(thick) && thick <= 1.5) || contains(sDesc, {'thin', '1mm', '1.25', '0.5'})
            reconTag = 'ThinSlice';
        end
        
        niiFilename = fullfile(outputFol, sprintf('%s_Ser%d_NonContrast_%s', pFolderID, sNum, reconTag));
        niiPath = [niiFilename '.nii'];

        % ================================================================
        % C5 NIfTI EXPORT FOR TOTALSEGMENTATOR
        % Write voxel data with MATLAB, then patch only the fixed NIfTI-1
        % header geometry fields. This avoids passing a modified niftiinfo
        % struct back into niftiwrite(), which can trigger header assertions
        % in some MATLAB releases.
        % DICOM coordinates = LPS; NIfTI sform = RAS.
        % ================================================================
        niiPath = [niiFilename '.nii'];

        try
            % 1) Write HU voxel data without normalization.
            if exist(niiPath, 'file'), delete(niiPath); end
            niftiwrite(single(I), niiFilename);

            % 2) Build physical affine from DICOM geometry.
            iopC3 = double(sMetaCell{1}.ImageOrientationPatient(:));
            dirColLPS = iopC3(1:3);
            dirRowLPS = iopC3(4:6);
            dirSliceLPS = cross(dirColLPS, dirRowLPS);
            dirSliceLPS = dirSliceLPS ./ norm(dirSliceLPS);
            originLPS = double(sMetaCell{1}.ImagePositionPatient(:));

            % MATLAB volume dimensions are [row, column, slice].
            % DICOM PixelSpacing = [row spacing, column spacing].
            axis1LPS = dirRowLPS * px;
            axis2LPS = dirColLPS * py;
            axis3LPS = dirSliceLPS * dz;

            % LPS -> RAS.
            LPS2RAS = diag([-1 -1 1]);
            axis1RAS = LPS2RAS * axis1LPS;
            axis2RAS = LPS2RAS * axis2LPS;
            axis3RAS = LPS2RAS * axis3LPS;
            originRAS = LPS2RAS * originLPS;
            A = [axis1RAS, axis2RAS, axis3RAS, originRAS; 0 0 0 1];

            % 3) Patch NIfTI-1 header in place.
            fid = fopen(niiPath, 'r+', 'ieee-le');
            if fid < 0
                error('C5:OpenNIfTI', 'Cannot open NIfTI for header patch: %s', niiPath);
            end
            cleanupObj = onCleanup(@() fclose(fid));

            fseek(fid, 0, 'bof');
            hdrBytes = fread(fid, 1, 'int32=>double');
            if hdrBytes ~= 348
                error('C5:UnexpectedHeader', ...
                    'Expected NIfTI-1 header (348 bytes), found %.0f bytes.', hdrBytes);
            end

            % pixdim starts at byte 76 (zero-based), 8 float32 values.
            fseek(fid, 76, 'bof');
            pixdim = fread(fid, 8, 'single=>single')';
            if numel(pixdim) ~= 8
                error('C5:PixdimRead', 'Could not read pixdim from %s', niiPath);
            end
            pixdim(1) = 1;
            pixdim(2:4) = single([px py dz]);
            fseek(fid, 76, 'bof');
            fwrite(fid, pixdim, 'single');

            % xyzt_units byte 123: millimeter = 2.
            fseek(fid, 123, 'bof');
            fwrite(fid, uint8(2), 'uint8');

            % qform_code byte 252; sform_code byte 254.
            fseek(fid, 252, 'bof');
            fwrite(fid, int16(0), 'int16');
            fwrite(fid, int16(1), 'int16');

            % srow_x/y/z bytes 280/296/312.
            fseek(fid, 280, 'bof'); fwrite(fid, single(A(1,:)), 'single');
            fseek(fid, 296, 'bof'); fwrite(fid, single(A(2,:)), 'single');
            fseek(fid, 312, 'bof'); fwrite(fid, single(A(3,:)), 'single');

            clear cleanupObj;

            % 4) Immediate QC.
            qcInfo = niftiinfo(niiPath);
            qcVol = niftiread(niiPath);

            % Some MATLAB releases omit trailing singleton dimensions from
            % PixelDimensions. Pad only for safe display/QC; true 3-D series
            % have already been enforced above.
            qcPD = double(qcInfo.PixelDimensions(:)');
            if numel(qcPD) < 3
                qcPD(end+1:3) = 1;
            end

            rawMin = double(min(qcVol(:)));
            rawMax = double(max(qcVol(:)));
            % Scanner padding can legitimately be -2048 or -3024 HU.
            % Show a second range excluding extreme padding so that the
            % clinically meaningful HU range can be compared across scanners.
            tissueVals = double(qcVol(qcVol > -1500));
            if isempty(tissueVals)
                tissueMin = NaN; tissueMax = NaN;
            else
                tissueMin = min(tissueVals); tissueMax = max(tissueVals);
            end

            fprintf('  [C5 NIfTI QC] %s Ser%d | Size=%s | Spacing=[%.3f %.3f %.3f] mm | RawHU=[%.0f, %.0f] | NonPaddingHU=[%.0f, %.0f] | qform=%d sform=%d\n', ...
                pFolderID, sNum, mat2str(size(qcVol)), ...
                qcPD(1), qcPD(2), qcPD(3), ...
                rawMin, rawMax, tissueMin, tissueMax, ...
                qcInfo.raw.qform_code, qcInfo.raw.sform_code);

            if max(abs(qcPD(1:3) - double([px py dz]))) > 1e-4
                error('C5:SpacingMismatch', ...
                    'NIfTI spacing mismatch for %s Ser%d. Expected %s, wrote %s', ...
                    pFolderID, sNum, mat2str([px py dz]), mat2str(qcPD(1:3)));
            end
            if qcInfo.raw.sform_code == 0
                error('C5:MissingSform', 'NIfTI sform_code is still 0 for %s Ser%d.', pFolderID, sNum);
            end

        catch ME
            % C5 exploratory mode: log the bad series and continue with the
            % remaining cohort instead of terminating the entire run.
            fprintf(2, '  [C5 NIfTI ERROR - SKIPPED] %s Ser%d: %s\n', pFolderID, sNum, ME.message);
            status = ['Log Only (C5 NIfTI export error: ' ME.identifier ')'];
            if exist(niiPath, 'file'), delete(niiPath); end
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
excelFilename = fullfile(outputFol, 'DICOM_Master_Log_Batch_C5.xlsx');
writetable(logData, excelFilename);

fprintf('\n====================================================================\n');
fprintf(' 🎉 [แก้ไขสำเร็จ!] ระบบ Ultimate Master Filter C5 ปิดบล็อกคำสั่งสมบูรณ์\n');
fprintf(' โครงสร้างลูปปิดครบถ้วน ไร้อาการหลุดรอด ไหลลื่นข้ามคืนได้เลยครับ\n');
fprintf('====================================================================\n');
