clear; clc; close all;

%% ========================================================================
%  VERTEBRAL BODY TRABECULAR QUANTIFICATION PIPELINE  (C4)
%
%  PURPOSE
%  - Measurement-only pass for stability / consistency checking.
%  - Reuses the already-created body-trabecular masks, e.g.
%       P001_L1_body_trabecular.nii.gz
%  - Intersects each body-trabecular mask AGAIN with the matching
%    TotalSegmentator vertebrae_L1-L4 mask as a safety gate.
%  - Uses the mid slice of the final 3-D body-trabecular intersection.
%  - Currently performs ONE measurement per level.
%  - The measurement loop is already prepared for 3 measurements later.
%  - Exports a diagnostic Long table + a template-like Wide Excel table.
%
%  IMPORTANT
%  - C4 does NOT rerun Skellytour. It only measures existing body masks.
%  - No abnormality interpretation is attempted here.
%  - HN is auto-mapped from F:\knomjeen_\Ref_list_30AUG.xlsx, sheet 'Code'.
% ========================================================================

%% 1. Paths / Settings
baseDataDir = 'F:\knomjeen_\File_non_contrast_nii1\';
excelFile   = fullfile(baseDataDir, 'CT_Trabecular_L1_L4_20Cases_C4.xlsx');

% HN <-> P00x reference mapping (worksheet 2: Code)
refListFile = 'F:\knomjeen_\Ref_list_30AUG.xlsx';
refSheet    = 'Code';

if ~exist(refListFile, 'file')
    error('ไม่พบไฟล์ HN reference: %s', refListFile);
end

hnMap = loadHNMap(refListFile, refSheet);
fprintf('=== [HN MAP] โหลด HN mapping จาก %s | Sheet=%s | %d codes ===\n', ...
    refListFile, refSheet, hnMap.Count);

% -------------------------------------------------------------------------
% Measurement plan
% -------------------------------------------------------------------------
% NOW: one measurement only = central slice.
% LATER: change nMeasurements from 1 to 3.
%
% Measurement order is intentionally:
%   HU_1 = central slice
%   HU_2 = central - 1 slice
%   HU_3 = central + 1 slice
%
% This preserves HU_1 as the central measurement when moving from 1 -> 3.
nMeasurements = 1;          % <-- CHANGE TO 3 LATER IF REQUIRED
measurementOffsets = [0 -1 +1];

% Optional display for quick QC (false is faster for batch work)
showQC = false;

%% 2. Find TotalSegmentator case folders
dirInfo = dir(fullfile(baseDataDir, '*_output_highres'));
dirInfo = dirInfo([dirInfo.isdir]);

if isempty(dirInfo)
    error('ไม่พบโฟลเดอร์ *_output_highres ใน %s', baseDataDir);
end

[~, sortIdx] = sort({dirInfo.name});
dirInfo = dirInfo(sortIdx);

fprintf('=== [C4 Start] ตรวจพบ TotalSegmentator output ทั้งหมด %d folders ===\n', numel(dirInfo));
fprintf('=== Measurement count per level = %d ===\n', nMeasurements);

%% 3. Result containers
longRows   = {};
wideRows   = {};
runLogRows = {};

longVarNames = { ...
    'HN','PatientID','SeriesName','Level','MeasurementNo', ...
    'MidBodySlice','SliceUsed','SliceOffset', ...
    'ROI_Pixels','Area_mm2','Mean_HU','SD_HU_ROI', ...
    'BodyMaskVoxelCount3D','FinalIntersectVoxelCount3D', ...
    'BodyMaskFile','Status'};

runLogVarNames = {'HN','PatientID','SeriesName','Stage','Status','Message'};

levelNames = {'L1','L2','L3','L4'};

%% 4. Main patient loop
for p = 1:numel(dirInfo)

    targetDirName = dirInfo(p).name;
    patientDir    = fullfile(baseDataDir, targetDirName);

    tokens = regexp(targetDirName, '^(P\d+)', 'tokens', 'once');
    if isempty(tokens)
        warning('ข้าม folder ที่อ่าน Patient ID ไม่ได้: %s', targetDirName);
        continue;
    end

    currentPatient = tokens{1};

    % Map processing code (P001...) back to HN from Ref_list_30AUG.xlsx / Code
    if isKey(hnMap, currentPatient)
        HN = hnMap(currentPatient);
    else
        HN = '';
        warning('[HN MAP] ไม่พบ HN สำหรับ %s ใน %s / %s', ...
            currentPatient, refListFile, refSheet);
    end

    seriesBase = regexprep(targetDirName, '_output_highres$', '');

    fprintf('\n============================================================\n');
    fprintf('▶ [C4] Processing %s (%d/%d) | %s\n', ...
        currentPatient, p, numel(dirInfo), seriesBase);

    %% 4.1 Exact CT NIfTI for this series
    ctSearch = dir(fullfile(baseDataDir, [seriesBase, '.nii*']));
    ctSearch = ctSearch(~[ctSearch.isdir]);

    if isempty(ctSearch)
        msg = sprintf('ไม่พบ CT NIfTI ที่ตรงกับ series: %s', seriesBase);
        warning('%s', msg);
        runLogRows(end+1,:) = {HN,currentPatient,seriesBase,'CT search','FAILED',msg}; %#ok<SAGROW>
        continue;
    end

    exactNii = find(strcmpi({ctSearch.name}, [seriesBase, '.nii']), 1);
    if ~isempty(exactNii)
        ctSearch = ctSearch(exactNii);
    else
        ctSearch = ctSearch(1);
    end

    ctFile = fullfile(ctSearch.folder, ctSearch.name);

    try
        CT     = double(niftiread(ctFile));
        ctInfo = niftiinfo(ctFile);
    catch ME
        msg = sprintf('อ่าน CT NIfTI ไม่สำเร็จ: %s', ME.message);
        warning('%s | %s', currentPatient, msg);
        runLogRows(end+1,:) = {HN,currentPatient,seriesBase,'CT read','FAILED',msg}; %#ok<SAGROW>
        continue;
    end

    if numel(ctInfo.PixelDimensions) >= 2
        px = double(ctInfo.PixelDimensions(1));
        py = double(ctInfo.PixelDimensions(2));
    else
        px = NaN;
        py = NaN;
    end

    %% 4.2 Patient-specific Skelly output folder (already created by C3)
    skellyOutDir = fullfile(patientDir, sprintf('%s_skelly_output', currentPatient));

    % Patient-wide temporary holders used to build the Wide sheet
    levelSummary = repmat(struct( ...
        'HU1',NaN,'HU2',NaN,'HU3',NaN,'MeanHU',NaN, ...
        'SDROI',NaN,'Area',NaN,'Slice',NaN,'Valid','No','Status','NOT_MEASURED'), 1, 4);

    %% 5. L1-L4 loop
    for L = 1:numel(levelNames)

        currentLevel = levelNames{L};

        %% 5.1 TotalSegmentator vertebra mask
        tsFile = fullfile(patientDir, sprintf('vertebrae_%s.nii.gz', currentLevel));

        if ~exist(tsFile, 'file')
            msg = sprintf('ไม่พบ TotalSegmentator mask: vertebrae_%s.nii.gz', currentLevel);
            fprintf('    [%s] %s\n', currentLevel, msg);
            runLogRows(end+1,:) = {HN,currentPatient,seriesBase,currentLevel,'FAILED',msg}; %#ok<SAGROW>
            levelSummary(L).Status = 'MISSING_TS_MASK';
            continue;
        end

        try
            tsMask = niftiread(tsFile) > 0;
        catch ME
            msg = sprintf('อ่าน TS mask ไม่สำเร็จ: %s', ME.message);
            warning('%s %s | %s', currentPatient, currentLevel, msg);
            runLogRows(end+1,:) = {HN,currentPatient,seriesBase,currentLevel,'FAILED',msg}; %#ok<SAGROW>
            levelSummary(L).Status = 'TS_READ_FAILED';
            continue;
        end

        %% 5.2 Find existing P00x_Lx_body_trabecular mask
        % Supports the normal filename plus common spelling / double-extension variants.
        bodyFile = findBodyTrabMask(patientDir, skellyOutDir, currentPatient, currentLevel);

        if isempty(bodyFile)
            msg = sprintf('ไม่พบ %s_%s_body_trabecular mask', currentPatient, currentLevel);
            fprintf('    [%s] %s\n', currentLevel, msg);
            runLogRows(end+1,:) = {HN,currentPatient,seriesBase,currentLevel,'FAILED',msg}; %#ok<SAGROW>
            levelSummary(L).Status = 'MISSING_BODY_TRAB_MASK';
            continue;
        end

        try
            bodyMask = niftiread(bodyFile) > 0;
        catch ME
            msg = sprintf('อ่าน body-trabecular mask ไม่สำเร็จ: %s', ME.message);
            warning('%s %s | %s', currentPatient, currentLevel, msg);
            runLogRows(end+1,:) = {HN,currentPatient,seriesBase,currentLevel,'FAILED',msg}; %#ok<SAGROW>
            levelSummary(L).Status = 'BODY_MASK_READ_FAILED';
            continue;
        end

        %% 5.3 Geometry QC
        if ~isequal(size(CT), size(tsMask)) || ~isequal(size(CT), size(bodyMask))
            msg = sprintf('Geometry mismatch CT=%s TS=%s BODY=%s', ...
                mat2str(size(CT)), mat2str(size(tsMask)), mat2str(size(bodyMask)));
            warning('%s %s | %s', currentPatient, currentLevel, msg);
            runLogRows(end+1,:) = {HN,currentPatient,seriesBase,currentLevel,'FAILED',msg}; %#ok<SAGROW>
            levelSummary(L).Status = 'GEOMETRY_MISMATCH';
            continue;
        end

        %% 5.4 Safety intersection: BODY-TRABECULAR x matching TS vertebral level
        % No additional morphology here. C4 deliberately measures the existing
        % body-trabecular mask to assess stability / consistency.
        bodyVoxelCount3D = nnz(bodyMask);
        finalMask3D      = bodyMask & tsMask;
        finalVoxelCount3D = nnz(finalMask3D);

        if finalVoxelCount3D == 0
            msg = 'EMPTY after body-trabecular x TotalSegmentator intersection';
            fprintf('    [%s] %s\n', currentLevel, msg);
            runLogRows(end+1,:) = {HN,currentPatient,seriesBase,currentLevel,'FAILED',msg}; %#ok<SAGROW>
            levelSummary(L).Status = 'EMPTY_INTERSECTION';
            continue;
        end

        %% 5.5 Define MID BODY slice from the final 3-D body mask
        hasMaskPerSlice = squeeze(any(any(finalMask3D, 1), 2));
        zList = find(hasMaskPerSlice);

        zMin = min(zList);
        zMax = max(zList);
        midTarget = round((zMin + zMax) / 2);

        % Select the closest slice that actually contains the body mask.
        [~, nearestIdx] = min(abs(zList - midTarget));
        midSlice = zList(nearestIdx);

        fprintf('    [%s] BODY SI=%d:%d | mid=%d | bodyVox=%d | intersectVox=%d\n', ...
            currentLevel, zMin, zMax, midSlice, bodyVoxelCount3D, finalVoxelCount3D);

        %% 5.6 Measurement loop
        % -----------------------------------------------------------------
        % CURRENTLY nMeasurements = 1.
        % Later, change nMeasurements = 3 only.
        % HU_1 = center, HU_2 = center-1, HU_3 = center+1.
        % -----------------------------------------------------------------
        levelMeanValues = nan(1, nMeasurements);

        for meas = 1:nMeasurements   % <-- 1 now; ready for 3 later

            sliceOffset = measurementOffsets(meas);
            sliceUsed   = midSlice + sliceOffset;

            % Safety for volume edges
            if sliceUsed < 1 || sliceUsed > size(CT,3)
                statusText = 'SLICE_OUT_OF_RANGE';
                longRows(end+1,:) = { ...
                    HN,currentPatient,seriesBase,currentLevel,meas, ...
                    double(midSlice),double(sliceUsed),double(sliceOffset), ...
                    0,NaN,NaN,NaN,double(bodyVoxelCount3D),double(finalVoxelCount3D), ...
                    bodyFile,statusText}; %#ok<SAGROW>
                continue;
            end

            % Use final body-trabecular ROI directly; NO 2-D bwareafilt here.
            roi2D = finalMask3D(:,:,sliceUsed);
            roiPixels = nnz(roi2D);

            if roiPixels == 0
                statusText = 'EMPTY_SLICE_ROI';
                longRows(end+1,:) = { ...
                    HN,currentPatient,seriesBase,currentLevel,meas, ...
                    double(midSlice),double(sliceUsed),double(sliceOffset), ...
                    0,0,NaN,NaN,double(bodyVoxelCount3D),double(finalVoxelCount3D), ...
                    bodyFile,statusText}; %#ok<SAGROW>
                continue;
            end

            ctSlice  = CT(:,:,sliceUsed);
            huValues = ctSlice(roi2D);
            huValues = huValues(isfinite(huValues));

            if isfinite(px) && isfinite(py)
                area_mm2 = double(roiPixels) * px * py;
            else
                area_mm2 = NaN;
            end

            if isempty(huValues)
                meanHU = NaN;
                sdHU   = NaN;
                statusText = 'NO_HU_VALUES';
            else
                meanHU = mean(huValues, 'omitnan');
                sdHU   = std(huValues, 0, 'omitnan');
                statusText = 'OK';
            end

            levelMeanValues(meas) = meanHU;

            longRows(end+1,:) = { ...
                HN,currentPatient,seriesBase,currentLevel,meas, ...
                double(midSlice),double(sliceUsed),double(sliceOffset), ...
                double(roiPixels),area_mm2,meanHU,sdHU, ...
                double(bodyVoxelCount3D),double(finalVoxelCount3D), ...
                bodyFile,statusText}; %#ok<SAGROW>

            fprintf('         M%d slice=%d | Area=%.1f mm^2 | Mean=%.1f HU | SD=%.1f HU | %s\n', ...
                meas, sliceUsed, area_mm2, meanHU, sdHU, statusText);

            if showQC && meas == 1
                figure(100 + L); clf;
                imagesc(ctSlice, [-200 300]); axis image off; colormap gray; hold on;
                B = bwboundaries(roi2D);
                for b = 1:numel(B)
                    plot(B{b}(:,2), B{b}(:,1), 'LineWidth', 1.5);
                end
                title(sprintf('%s %s | Central body slice %d', ...
                    currentPatient,currentLevel,sliceUsed));
                drawnow;
            end
        end

        %% 5.7 Level summary for template-like Wide sheet
        % Measurement fields
        if nMeasurements >= 1, levelSummary(L).HU1 = levelMeanValues(1); end
        if nMeasurements >= 2, levelSummary(L).HU2 = levelMeanValues(2); end
        if nMeasurements >= 3, levelSummary(L).HU3 = levelMeanValues(3); end

        validMeans = levelMeanValues(isfinite(levelMeanValues));
        if ~isempty(validMeans)
            levelSummary(L).MeanHU = mean(validMeans, 'omitnan');
        end

        % The template has only one ROI area / one ROI SD / one slice number.
        % Therefore use Measurement 1 (central body slice) for these fields.
        idxLong = find(strcmp(longRows(:,2), currentPatient) & ...
                       strcmp(longRows(:,4), currentLevel) & ...
                       cell2mat(longRows(:,5)) == 1, 1, 'last');

        if ~isempty(idxLong)
            levelSummary(L).Slice = longRows{idxLong,7};
            levelSummary(L).Area  = longRows{idxLong,10};
            levelSummary(L).SDROI = longRows{idxLong,12};
            levelSummary(L).Status = longRows{idxLong,16};

            if strcmp(levelSummary(L).Status,'OK')
                levelSummary(L).Valid = 'Yes';
            end
        end
    end

    %% 6. Build one Wide row for this patient
    % Columns are intentionally close to 02_BONE_L1_L4 while retaining PatientID.
    row = {HN,currentPatient,seriesBase, ...
           sprintf('Automated mid-vertebral-body trabecular ROI; %d measurement(s)', nMeasurements)};

    levelMeansForPatient = nan(1,4);

    for L = 1:4
        row = [row, { ... %#ok<AGROW>
            levelSummary(L).HU1, ...
            levelSummary(L).HU2, ...
            levelSummary(L).HU3, ...
            levelSummary(L).MeanHU, ...
            levelSummary(L).SDROI, ...
            levelSummary(L).Area, ...
            levelSummary(L).Slice, ...
            levelSummary(L).Valid, ...
            '', ... % Abnormality intentionally blank for clinical review
            levelSummary(L).Status}];

        levelMeansForPatient(L) = levelSummary(L).MeanHU;
    end

    validLevelMeans = levelMeansForPatient(isfinite(levelMeansForPatient));
    if isempty(validLevelMeans)
        meanValidL1L4 = NaN;
        nValidLevels = 0;
        reviewRequired = 'Yes';
    else
        meanValidL1L4 = mean(validLevelMeans, 'omitnan');
        nValidLevels = numel(validLevelMeans);
        if nValidLevels == 4
            reviewRequired = 'No';
        else
            reviewRequired = 'Yes';
        end
    end

    comments = '';
    if nValidLevels < 4
        comments = sprintf('Only %d/4 vertebral levels quantified automatically; review required.', nValidLevels);
    end

    row = [row, {meanValidL1L4,nValidLevels,reviewRequired,comments}]; %#ok<AGROW>
    wideRows(end+1,:) = row; %#ok<SAGROW>

    runLogRows(end+1,:) = {HN,currentPatient,seriesBase,'Patient','COMPLETED','C4 L1-L4 measurement loop completed'}; %#ok<SAGROW>
end

%% 7. Create LONG table
if isempty(longRows)
    longTable = cell2table(cell(0,numel(longVarNames)), 'VariableNames', longVarNames);
else
    longTable = cell2table(longRows, 'VariableNames', longVarNames);
end

%% 8. Create WIDE / template-like table
wideNames = {'HN','PatientID','SeriesName','Measurement_Method'};
for L = 1:4
    lev = sprintf('L%d',L);
    wideNames = [wideNames, { ... %#ok<AGROW>
        [lev '_HU_1'], [lev '_HU_2'], [lev '_HU_3'], ...
        [lev '_HU_mean'], [lev '_HU_SD_ROI'], [lev '_ROI_Area_mm2'], ...
        [lev '_Slice_Index_NIfTI'], [lev '_Valid'], [lev '_Abnormality'], [lev '_Auto_Status']}];
end
wideNames = [wideNames, {'Mean_Valid_L1_L4_HU','Number_of_Level_Means','Review_Required','Comments'}];

if isempty(wideRows)
    wideTable = cell2table(cell(0,numel(wideNames)), 'VariableNames', wideNames);
else
    wideTable = cell2table(wideRows, 'VariableNames', wideNames);
end

%% 9. Run log
if isempty(runLogRows)
    runLog = cell2table(cell(0,numel(runLogVarNames)), 'VariableNames', runLogVarNames);
else
    runLog = cell2table(runLogRows, 'VariableNames', runLogVarNames);
end

%% 10. Parameters sheet
parameterTable = table( ...
    {'nMeasurements';'measurementOffsets';'PrimarySlice';'ROI_Source';'SafetyIntersection';'AbnormalityAssessment'}, ...
    {num2str(nMeasurements);mat2str(measurementOffsets(1:nMeasurements)); ...
     'Mid slice of final 3-D body-trabecular mask'; ...
     'Existing P00x_L1-L4_body_trabecular mask'; ...
     'Body-trabecular mask AND matching TotalSegmentator vertebra mask'; ...
     'Not performed by C4; left for clinical review'}, ...
    'VariableNames', {'Parameter','Value'});

%% 11. Write Excel
writetable(wideTable,      excelFile, 'Sheet', '02_BONE_L1_L4_AUTO');
writetable(longTable,      excelFile, 'Sheet', 'Measurement_Long');
writetable(runLog,         excelFile, 'Sheet', 'Run_Log');
writetable(parameterTable, excelFile, 'Sheet', 'Parameters');

fprintf('\n====================================================================\n');
fprintf(' DONE C4: Existing body-trabecular mask -> TS safety intersection -> mid-body measurement\n');
fprintf(' Measurements per level: %d\n', nMeasurements);
fprintf(' Excel: %s\n', excelFile);
fprintf('====================================================================\n');

%% ========================================================================
% LOCAL FUNCTION: load P00x <-> HN mapping from Ref_list_30AUG.xlsx / Code
% ========================================================================
function hnMap = loadHNMap(refListFile, refSheet)

raw = readcell(refListFile, 'Sheet', refSheet);
if isempty(raw) || size(raw,1) < 2
    error('HN reference sheet %s ว่างหรืออ่านไม่ได้', refSheet);
end

headers = strtrim(string(raw(1,:)));
hnCol   = find(strcmpi(headers, 'HN'), 1);
codeCol = find(strcmpi(headers, 'Code'), 1);

if isempty(hnCol) || isempty(codeCol)
    error('Sheet %s ต้องมีคอลัมน์ HN และ Code', refSheet);
end

hnMap = containers.Map('KeyType','char','ValueType','char');

for r = 2:size(raw,1)
    codeValue = raw{r,codeCol};
    hnValue   = raw{r,hnCol};

    % ---- Code ----
    if isempty(codeValue) || (isnumeric(codeValue) && isnan(codeValue))
        continue;
    end
    codeStr = upper(strtrim(char(string(codeValue))));
    if isempty(codeStr) || ~startsWith(codeStr,'P')
        continue;
    end

    % ---- HN ----
    % HN is handled as TEXT to preserve leading zeros such as 0463030.
    if isnumeric(hnValue)
        if isempty(hnValue) || isnan(hnValue)
            hnStr = '';
        else
            hnStr = sprintf('%07d', round(double(hnValue)));
        end
    else
        hnStr = strtrim(char(string(hnValue)));
        % If Excel/text import produced a shorter all-numeric HN, pad to 7 digits.
        if ~isempty(regexp(hnStr, '^\d+$', 'once')) && numel(hnStr) < 7
            hnStr = sprintf('%07d', str2double(hnStr));
        end
    end

    if isempty(hnStr)
        continue;
    end

    if isKey(hnMap, codeStr)
        warning('[HN MAP] Duplicate Code %s ใน sheet %s; ใช้ค่ารายการแรก (%s)', ...
            codeStr, refSheet, hnMap(codeStr));
        continue;
    end

    hnMap(codeStr) = hnStr;
end

if hnMap.Count == 0
    error('ไม่สามารถสร้าง HN mapping จาก %s / %s ได้', refListFile, refSheet);
end
end

%% ========================================================================
% LOCAL FUNCTION: locate existing body-trabecular mask robustly
% ========================================================================
function bodyFile = findBodyTrabMask(patientDir, skellyOutDir, patientID, levelName)

bodyFile = '';

% Preferred / known filename variants.
patterns = { ...
    sprintf('%s_%s_body_trabecular.nii.gz', patientID, levelName), ...
    sprintf('%s_%s_body_trabecular.nii.nii.gz', patientID, levelName), ...
    sprintf('%s_%s_body_trabaculae.nii.gz', patientID, levelName), ...
    sprintf('%s_%s_body_trabaculae.nii.nii.gz', patientID, levelName)};

searchDirs = {skellyOutDir, patientDir};

for d = 1:numel(searchDirs)
    if ~exist(searchDirs{d}, 'dir')
        continue;
    end
    for k = 1:numel(patterns)
        f = fullfile(searchDirs{d}, patterns{k});
        if exist(f, 'file')
            bodyFile = f;
            return;
        end
    end
end

% Fallback recursive search in the patient's TS output folder.
% This also catches small filename variations produced during testing.
searchPatterns = { ...
    sprintf('%s_%s_body_trabecular*.nii*', patientID, levelName), ...
    sprintf('%s_%s_body_trabaculae*.nii*', patientID, levelName)};

for k = 1:numel(searchPatterns)
    hits = dir(fullfile(patientDir, '**', searchPatterns{k}));
    hits = hits(~[hits.isdir]);
    if ~isempty(hits)
        bodyFile = fullfile(hits(1).folder, hits(1).name);
        return;
    end
end
end
