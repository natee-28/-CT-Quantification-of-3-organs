clear; clc; close all;

%% ========================================================================
%  STEP 2: SKELLYTOUR + TOTALSEGMENTATOR VERTEBRAL TRABECULAR PIPELINE
%  File: step2_Skel_TS.m
%
%  Combined workflow from skell_ts_exc_C3 + skell_ts_exc_C4:
%
%    Original non-contrast CT NIfTI
%            |
%            +--> Skellytour FULL model, GPU 0, --subseg
%            |       (NO --fast)
%            |
%            +--> Skellytour label == 1 = trabecular compartment
%            |
%    TotalSegmentator vertebrae_L1 ... vertebrae_L4
%            |
%            +--> TS x Skelly trabecular intersection
%            |
%            +--> axial morphological opening in PHYSICAL mm
%                 + largest 2-D component on each slice
%                 = body-trabecular candidate
%            |
%            +--> save P00x_L1-L4_body_trabecular.nii.gz
%            |
%            +--> determine MID-VERTEBRAL-BODY slice
%            |
%            +--> measurement loop:
%                 Area (mm2), Mean HU, SD HU
%            |
%            +--> Excel (HN mapped from Ref_list_30AUG.xlsx / Code)
%
%  Clinical abnormalities (fracture, hemangioma, focal sclerosis, etc.)
%  are intentionally NOT assessed by this script.
%
%  IMPORTANT:
%  - nMeasurements = 1 now.
%  - If clinical protocol later confirms 3 adjacent measurements,
%    change ONLY nMeasurements = 3.
%    Measurement order is center, center-1, center+1.
% ========================================================================

%% 1. USER SETTINGS
% ---- Current working folder ----
% If the other computer uses File_non_contrast_nii1, change ONLY this line.
baseDataDir = 'F:\knomjeen_\File_non_contrast_nii1\';

anacondaBatPath = 'C:\Users\ADMIN\anaconda3\condabin\conda.bat';

% HN mapping
refListFile = 'F:\knomjeen_\Ref_list_30AUG.xlsx';
refSheet    = 'Code';

% Output Excel
excelFile = fullfile(baseDataDir, 'CT_Trabecular_L1_L4_step2_Skel_TS3.xlsx');

%% 1.1 Skellytour settings
skellyModel = 'medium';
gpuID       = 0;

% If an OLD Skellytour output was generated with --fast, rerun FULL.
rerunIfFast = true;

%% 1.2 Vertebral-body isolation settings (from C3)
% Morphological opening radius in physical units.
bodyOpeningRadius_mm = 3.0;

% Tiny superior/inferior remnants are ignored when defining body SI extent.
% Slices >= 20% of the maximum body area define the body range.
bodyPresenceFraction = 0.20;

% Do not attempt body isolation on tiny slices.
minSlicePixels = 20;

%% 1.3 Measurement settings (from C4)
nMeasurements = 3;             % <-- change to 3 later if protocol confirms
measurementOffsets = [0 -1 1]; % M1=center, M2=center-1, M3=center+1

showQC = false;                % true = show central ROI overlay
saveBodyMasks = true;

if nMeasurements < 1 || nMeasurements > 3
    error('nMeasurements ต้องเป็น 1, 2 หรือ 3');
end

%% 2. STARTUP QC
if ~isfolder(baseDataDir)
    error('ไม่พบ baseDataDir: %s', baseDataDir);
end

if ~isfile(anacondaBatPath)
    warning('ไม่พบ conda.bat: %s', anacondaBatPath);
end

fprintf('\n============================================================\n');
fprintf(' STEP 2: SKELLYTOUR + TOTALSEGMENTATOR\n');
fprintf(' Base folder           : %s\n', baseDataDir);
fprintf(' Skellytour            : FULL, %s, GPU %d, --subseg\n', skellyModel, gpuID);
fprintf(' Body opening radius   : %.1f mm\n', bodyOpeningRadius_mm);
fprintf(' Body SI threshold     : %.0f%% of max area\n', bodyPresenceFraction*100);
fprintf(' Measurements / level  : %d\n', nMeasurements);
fprintf('============================================================\n');

%% 3. Load HN mapping
hnMap = loadHNMap(refListFile, refSheet);
fprintf('HN mapping loaded: %d records\n', hnMap.Count);

%% 4. Find TotalSegmentator folders
dirInfo = dir(fullfile(baseDataDir, '*_output_highres'));
dirInfo = dirInfo([dirInfo.isdir]);

if isempty(dirInfo)
    error('ไม่พบ *_output_highres ใน %s', baseDataDir);
end

[~,sortIdx] = sort({dirInfo.name});
dirInfo = dirInfo(sortIdx);

fprintf('TotalSegmentator output folders: %d\n', numel(dirInfo));

%% 5. Result containers
longRows   = {};
wideRows   = {};
runLogRows = {};

longVarNames = { ...
    'HN','PatientID','SeriesName','Level','MeasurementNo', ...
    'BodySliceMin','BodySliceMax','MidBodySlice', ...
    'SliceUsed','SliceOffset', ...
    'ROI_Pixels','Area_mm2','Mean_HU','SD_HU_ROI', ...
    'RawTrabVoxelCount3D','BodyTrabVoxelCount3D', ...
    'FinalIntersectVoxelCount3D', ...
    'OpeningRadius_mm','OpeningRadius_px', ...
    'BodyMaskFile','Status'};

runLogVarNames = {'HN','PatientID','SeriesName','Stage','Status','Message'};

levelNames = {'L1','L2','L3','L4'};

%% 6. MAIN PATIENT LOOP
for p = 1:numel(dirInfo)

    targetDirName = dirInfo(p).name;
    patientDir    = fullfile(baseDataDir, targetDirName);

    tokens = regexp(targetDirName, '^(P\d+)', 'tokens', 'once');
    if isempty(tokens)
        warning('ข้าม folder ที่อ่าน Patient ID ไม่ได้: %s', targetDirName);
        continue;
    end

    currentPatient = tokens{1};
    seriesBase = regexprep(targetDirName, '_output_highres$', '');

    %% 6.1 HN
    if isKey(hnMap,currentPatient)
        HN = hnMap(currentPatient);
    else
        HN = '';
        warning('[HN MAP] ไม่พบ HN สำหรับ %s', currentPatient);
    end

    fprintf('\n============================================================\n');
    fprintf('▶ Processing %s (%d/%d) | HN=%s | %s\n', ...
        currentPatient,p,numel(dirInfo),HN,seriesBase);

    %% 6.2 Exact CT NIfTI
    ctSearch = dir(fullfile(baseDataDir, [seriesBase '.nii*']));
    ctSearch = ctSearch(~[ctSearch.isdir]);

    if isempty(ctSearch)
        msg = sprintf('CT_NOT_FOUND: %s',seriesBase);
        warning('%s',msg);
        runLogRows(end+1,:) = {HN,currentPatient,seriesBase,'CT search','FAILED',msg}; %#ok<SAGROW>
        continue;
    end

    exactNii = find(strcmpi({ctSearch.name}, [seriesBase '.nii']),1);
    if ~isempty(exactNii)
        ctSearch = ctSearch(exactNii);
    else
        ctSearch = ctSearch(1);
    end

    ctFile = fullfile(ctSearch.folder,ctSearch.name);

    %% 6.3 Patient Skellytour folder
    skellyOutDir = fullfile(patientDir, sprintf('%s_skelly_output',currentPatient));
    if ~exist(skellyOutDir,'dir')
        mkdir(skellyOutDir);
    end

    %% 6.4 Find existing Skellytour FINAL subseg output
    skellySearch = findSkellyOutput(skellyOutDir);

    % Detect whether existing result came from --fast
    detectedOldFast = false;
    skellyLogFile = fullfile(skellyOutDir,'log.txt');

    if ~isempty(skellySearch) && isfile(skellyLogFile)
        try
            logText = fileread(skellyLogFile);
            detectedOldFast = contains(logText,'Fast mode enabled','IgnoreCase',true);
        catch
            detectedOldFast = false;
        end
    end

    needRunSkelly = isempty(skellySearch) || (rerunIfFast && detectedOldFast);

    %% 6.5 Run Skellytour FULL if needed
    if needRunSkelly

        overwriteArg = '';
        if detectedOldFast
            fprintf(' -> พบ output เก่าจาก --fast: rerun FULL...\n');
            overwriteArg = ' --overwrite';
        else
            fprintf(' -> ไม่พบ Skellytour FULL output: เริ่ม AI (FULL, GPU %d)...\n',gpuID);
        end

        cmd = sprintf(['call "%s" activate ts_env && ' ...
            'skellytour -i "%s" -o "%s" -m %s -d gpu -g %d --subseg%s'], ...
            anacondaBatPath,ctFile,skellyOutDir,skellyModel,gpuID,overwriteArg);

        tic;
        [status,cmdout] = system(cmd);
        elapsedSec = toc;

        if status ~= 0
            msg = sprintf('Skellytour failed (status=%d): %s',status,strtrim(cmdout));
            warning('%s | %s',currentPatient,msg);
            runLogRows(end+1,:) = {HN,currentPatient,seriesBase,'Skellytour','FAILED',msg}; %#ok<SAGROW>
            continue;
        end

        fprintf(' -> Skellytour FULL เสร็จใน %.1f s\n',elapsedSec);

        skellySearch = findSkellyOutput(skellyOutDir);

        if isempty(skellySearch)
            msg = 'SKELLY_OUTPUT_NOT_FOUND_AFTER_SUCCESS';
            warning('%s | %s',currentPatient,msg);
            runLogRows(end+1,:) = {HN,currentPatient,seriesBase,'Skellytour output','FAILED',msg}; %#ok<SAGROW>
            continue;
        end

    else
        fprintf(' -> พบ Skellytour FULL output เดิม: reuse\n');
    end

    skellyFile = fullfile(skellySearch.folder,skellySearch.name);

    %% 6.6 Load CT + Skellytour
    try
        CT         = double(niftiread(ctFile));
        ctInfo     = niftiinfo(ctFile);
        skellyMask = niftiread(skellyFile);
    catch ME
        msg = sprintf('NIFTI_READ_ERROR: %s',ME.message);
        warning('%s | %s',currentPatient,msg);
        runLogRows(end+1,:) = {HN,currentPatient,seriesBase,'NIfTI read','FAILED',msg}; %#ok<SAGROW>
        continue;
    end

    if ~isequal(size(CT),size(skellyMask))
        msg = sprintf('CT_SKELLY_GEOMETRY_MISMATCH CT=%s SKELLY=%s', ...
            mat2str(size(CT)),mat2str(size(skellyMask)));
        warning('%s | %s',currentPatient,msg);
        runLogRows(end+1,:) = {HN,currentPatient,seriesBase,'Geometry QC','FAILED',msg}; %#ok<SAGROW>
        continue;
    end

    % User-confirmed Skellytour trabecular label
    skellyTrabMask = (skellyMask == 1);

    if ~any(skellyTrabMask(:))
        msg = 'SKELLY_LABEL1_EMPTY';
        warning('%s | %s',currentPatient,msg);
        runLogRows(end+1,:) = {HN,currentPatient,seriesBase,'Skelly label','FAILED',msg}; %#ok<SAGROW>
        continue;
    end

    %% 6.7 Physical spacing + case-specific morphology
    if numel(ctInfo.PixelDimensions) >= 2
        px = double(ctInfo.PixelDimensions(1));
        py = double(ctInfo.PixelDimensions(2));
    else
        px = NaN;
        py = NaN;
    end

    if isfinite(px) && isfinite(py) && px>0 && py>0
        meanInPlaneSpacing = mean([px py]);
        openingRadius_px = max(1,round(bodyOpeningRadius_mm / meanInPlaneSpacing));
    else
        openingRadius_px = 3;
    end

    seBody = strel('disk',openingRadius_px,0);

    %% 6.8 Patient-wide summary holders
    levelSummary = repmat(struct( ...
        'HU1',NaN,'HU2',NaN,'HU3',NaN,'MeanHU',NaN, ...
        'SDROI',NaN,'Area',NaN,'Slice',NaN, ...
        'Valid','No','Status','NOT_MEASURED'),1,4);

    %% 7. L1-L4 LOOP
    for L = 1:numel(levelNames)

        currentLevel = levelNames{L};
        tsFile = fullfile(patientDir,sprintf('vertebrae_%s.nii.gz',currentLevel));

        %% 7.1 Read matching TS vertebral mask
        if ~isfile(tsFile)
            msg = sprintf('MISSING_TS_MASK: vertebrae_%s.nii.gz',currentLevel);
            fprintf('    [%s] %s\n',currentLevel,msg);
            runLogRows(end+1,:) = {HN,currentPatient,seriesBase,currentLevel,'FAILED',msg}; %#ok<SAGROW>
            levelSummary(L).Status = 'MISSING_TS_MASK';
            continue;
        end

        try
            tsMask = niftiread(tsFile) > 0;
        catch ME
            msg = sprintf('TS_READ_FAILED: %s',ME.message);
            warning('%s %s | %s',currentPatient,currentLevel,msg);
            runLogRows(end+1,:) = {HN,currentPatient,seriesBase,currentLevel,'FAILED',msg}; %#ok<SAGROW>
            levelSummary(L).Status = 'TS_READ_FAILED';
            continue;
        end

        if ~isequal(size(tsMask),size(CT))
            msg = sprintf('TS_GEOMETRY_MISMATCH TS=%s CT=%s', ...
                mat2str(size(tsMask)),mat2str(size(CT)));
            warning('%s %s | %s',currentPatient,currentLevel,msg);
            runLogRows(end+1,:) = {HN,currentPatient,seriesBase,currentLevel,'FAILED',msg}; %#ok<SAGROW>
            levelSummary(L).Status = 'TS_GEOMETRY_MISMATCH';
            continue;
        end

        %% 7.2 C3: raw trabecular intersection
        rawTrabMask = tsMask & skellyTrabMask;
        rawTrabVoxelCount3D = nnz(rawTrabMask);

        if rawTrabVoxelCount3D == 0
            msg = 'EMPTY_TS_X_SKELLY_INTERSECTION';
            fprintf('    [%s] %s\n',currentLevel,msg);
            runLogRows(end+1,:) = {HN,currentPatient,seriesBase,currentLevel,'FAILED',msg}; %#ok<SAGROW>
            levelSummary(L).Status = msg;
            continue;
        end

        %% 7.3 C3: BODY-ONLY trabecular candidate
        % Opening removes narrow posterior connections.
        % Manual largest-component selection avoids bwareafilt tie warnings.
        bodyTrabMask = false(size(rawTrabMask));

        for z = 1:size(rawTrabMask,3)

            rawSlice = rawTrabMask(:,:,z);

            if nnz(rawSlice) < minSlicePixels
                continue;
            end

            openedSlice = imopen(rawSlice,seBody);

            if any(openedSlice(:))
                largestSlice = keepLargestComponent2D(openedSlice,8);
                bodyTrabMask(:,:,z) = largestSlice & rawSlice;
            end
        end

        bodyTrabVoxelCount3D = nnz(bodyTrabMask);

        if bodyTrabVoxelCount3D == 0
            msg = 'EMPTY_BODY_AFTER_OPENING';
            fprintf('    [%s] %s\n',currentLevel,msg);
            runLogRows(end+1,:) = {HN,currentPatient,seriesBase,currentLevel,'FAILED',msg}; %#ok<SAGROW>
            levelSummary(L).Status = msg;
            continue;
        end

        %% 7.4 C3: body SI extent + mid-vertebral-body slice
        areaPixPerSlice = squeeze(sum(sum(bodyTrabMask,1),2));
        maxAreaPix = max(areaPixPerSlice);

        validBodySlices = find(areaPixPerSlice >= bodyPresenceFraction * maxAreaPix);

        if isempty(validBodySlices)
            validBodySlices = find(areaPixPerSlice > 0);
        end

        bodySliceMin = min(validBodySlices);
        bodySliceMax = max(validBodySlices);
        targetMid = round((bodySliceMin + bodySliceMax)/2);

        nonEmptyBodySlices = find(areaPixPerSlice > 0);
        [~,nearestIdx] = min(abs(nonEmptyBodySlices-targetMid));
        midBodySlice = nonEmptyBodySlices(nearestIdx);

        %% 7.5 Save body-trabecular NIfTI
        outBodyNii = fullfile(skellyOutDir, ...
            sprintf('%s_%s_body_trabecular.nii',currentPatient,currentLevel));
        outBodyGz = [outBodyNii '.gz'];

        if saveBodyMasks
            try
                % Avoid stale files from older runs.
                if isfile(outBodyGz)
                    delete(outBodyGz);
                end

                niiInfo = niftiinfo(tsFile);
                niftiwrite(uint8(bodyTrabMask),outBodyNii,niiInfo,'Compressed',true);

            catch ME
                warning('%s %s | BODY_MASK_SAVE_FAILED: %s', ...
                    currentPatient,currentLevel,ME.message);
            end
        end

        %% 7.6 C4: safety intersection with matching TS level
        finalMask3D = bodyTrabMask & tsMask;
        finalVoxelCount3D = nnz(finalMask3D);

        if finalVoxelCount3D == 0
            msg = 'EMPTY_FINAL_INTERSECTION';
            fprintf('    [%s] %s\n',currentLevel,msg);
            runLogRows(end+1,:) = {HN,currentPatient,seriesBase,currentLevel,'FAILED',msg}; %#ok<SAGROW>
            levelSummary(L).Status = msg;
            continue;
        end

        fprintf(['    [%s] BODY SI=%d:%d | mid=%d | rawVox=%d | ' ...
                 'bodyVox=%d | finalVox=%d\n'], ...
            currentLevel,bodySliceMin,bodySliceMax,midBodySlice, ...
            rawTrabVoxelCount3D,bodyTrabVoxelCount3D,finalVoxelCount3D);

        %% 7.7 C4: measurement loop
        levelMeanValues = nan(1,nMeasurements);

        for meas = 1:nMeasurements

            sliceOffset = measurementOffsets(meas);
            sliceUsed = midBodySlice + sliceOffset;

            if sliceUsed < 1 || sliceUsed > size(CT,3)
                statusText = 'SLICE_OUT_OF_RANGE';

                longRows(end+1,:) = { ...
                    HN,currentPatient,seriesBase,currentLevel,meas, ...
                    double(bodySliceMin),double(bodySliceMax),double(midBodySlice), ...
                    double(sliceUsed),double(sliceOffset), ...
                    0,NaN,NaN,NaN, ...
                    double(rawTrabVoxelCount3D),double(bodyTrabVoxelCount3D), ...
                    double(finalVoxelCount3D), ...
                    bodyOpeningRadius_mm,double(openingRadius_px), ...
                    outBodyGz,statusText}; %#ok<SAGROW>
                continue;
            end

            % Directly measure the generated body-trabecular mask.
            % NO additional 2-D morphology here.
            roi2D = finalMask3D(:,:,sliceUsed);
            roiPixels = nnz(roi2D);

            if roiPixels == 0
                statusText = 'EMPTY_SLICE_ROI';

                longRows(end+1,:) = { ...
                    HN,currentPatient,seriesBase,currentLevel,meas, ...
                    double(bodySliceMin),double(bodySliceMax),double(midBodySlice), ...
                    double(sliceUsed),double(sliceOffset), ...
                    0,0,NaN,NaN, ...
                    double(rawTrabVoxelCount3D),double(bodyTrabVoxelCount3D), ...
                    double(finalVoxelCount3D), ...
                    bodyOpeningRadius_mm,double(openingRadius_px), ...
                    outBodyGz,statusText}; %#ok<SAGROW>
                continue;
            end

            if isfinite(px) && isfinite(py)
                area_mm2 = double(roiPixels) * px * py;
            else
                area_mm2 = NaN;
            end

            ctSlice = CT(:,:,sliceUsed);
            huValues = ctSlice(roi2D);
            huValues = huValues(isfinite(huValues));

            if isempty(huValues)
                meanHU = NaN;
                sdHU = NaN;
                statusText = 'NO_HU_VALUES';
            else
                meanHU = mean(huValues,'omitnan');
                sdHU = std(huValues,0,'omitnan');
                statusText = 'OK';
            end

            levelMeanValues(meas) = meanHU;

            longRows(end+1,:) = { ...
                HN,currentPatient,seriesBase,currentLevel,meas, ...
                double(bodySliceMin),double(bodySliceMax),double(midBodySlice), ...
                double(sliceUsed),double(sliceOffset), ...
                double(roiPixels),area_mm2,meanHU,sdHU, ...
                double(rawTrabVoxelCount3D),double(bodyTrabVoxelCount3D), ...
                double(finalVoxelCount3D), ...
                bodyOpeningRadius_mm,double(openingRadius_px), ...
                outBodyGz,statusText}; %#ok<SAGROW>

            fprintf('         M%d slice=%d | Area=%.1f mm^2 | Mean=%.1f HU | SD=%.1f HU | %s\n', ...
                meas,sliceUsed,area_mm2,meanHU,sdHU,statusText);

            if showQC && meas == 1
                figure(100+L); clf;
                imagesc(ctSlice,[-200 300]);
                axis image off;
                colormap gray;
                hold on;

                B = bwboundaries(roi2D);
                for b = 1:numel(B)
                    plot(B{b}(:,2),B{b}(:,1),'LineWidth',1.5);
                end

                title(sprintf('%s %s | Mid-body slice %d', ...
                    currentPatient,currentLevel,sliceUsed));
                drawnow;
            end
        end

        %% 7.8 Template-like per-level summary
        if nMeasurements >= 1
            levelSummary(L).HU1 = levelMeanValues(1);
        end
        if nMeasurements >= 2
            levelSummary(L).HU2 = levelMeanValues(2);
        end
        if nMeasurements >= 3
            levelSummary(L).HU3 = levelMeanValues(3);
        end

        validMeans = levelMeanValues(isfinite(levelMeanValues));
        if ~isempty(validMeans)
            levelSummary(L).MeanHU = mean(validMeans,'omitnan');
        end

        % Area / ROI SD / slice number are taken from Measurement 1,
        % matching the current single-central-slice working method.
        idxLong = find( ...
            strcmp(longRows(:,2),currentPatient) & ...
            strcmp(longRows(:,4),currentLevel) & ...
            cell2mat(longRows(:,5)) == 1, ...
            1,'last');

        if ~isempty(idxLong)
            levelSummary(L).Slice  = longRows{idxLong,9};
            levelSummary(L).Area   = longRows{idxLong,12};
            levelSummary(L).SDROI  = longRows{idxLong,14};
            levelSummary(L).Status = longRows{idxLong,21};

            if strcmp(levelSummary(L).Status,'OK')
                levelSummary(L).Valid = 'Yes';
            end
        end
    end

    %% 8. One WIDE row per patient
    methodText = sprintf([ ...
        'Skellytour FULL GPU label1 x TotalSegmentator; ' ...
        'axial opening %.1f mm; mid-vertebral-body; %d measurement(s)'], ...
        bodyOpeningRadius_mm,nMeasurements);

    row = {HN,currentPatient,seriesBase,methodText};

    levelMeansForPatient = nan(1,4);

    for L = 1:4
        row = [row,{ ... %#ok<AGROW>
            levelSummary(L).HU1, ...
            levelSummary(L).HU2, ...
            levelSummary(L).HU3, ...
            levelSummary(L).MeanHU, ...
            levelSummary(L).SDROI, ...
            levelSummary(L).Area, ...
            levelSummary(L).Slice, ...
            levelSummary(L).Valid, ...
            '', ... % Abnormality intentionally blank
            levelSummary(L).Status}];

        levelMeansForPatient(L) = levelSummary(L).MeanHU;
    end

    validLevelMeans = levelMeansForPatient(isfinite(levelMeansForPatient));

    if isempty(validLevelMeans)
        meanValidL1L4 = NaN;
        nValidLevels = 0;
        reviewRequired = 'Yes';
    else
        meanValidL1L4 = mean(validLevelMeans,'omitnan');
        nValidLevels = numel(validLevelMeans);

        if nValidLevels == 4
            reviewRequired = 'No';
        else
            reviewRequired = 'Yes';
        end
    end

    comments = '';
    if nValidLevels < 4
        comments = sprintf('Only %d/4 vertebral levels quantified automatically; review required.', ...
            nValidLevels);
    end

    row = [row,{meanValidL1L4,nValidLevels,reviewRequired,comments}]; %#ok<AGROW>
    wideRows(end+1,:) = row; %#ok<SAGROW>

    runLogRows(end+1,:) = { ...
        HN,currentPatient,seriesBase,'Patient','COMPLETED', ...
        'Skellytour + body-mask generation + measurement completed'}; %#ok<SAGROW>
end

%% 9. CREATE LONG TABLE
if isempty(longRows)
    longTable = cell2table(cell(0,numel(longVarNames)), ...
        'VariableNames',longVarNames);
else
    longTable = cell2table(longRows,'VariableNames',longVarNames);
end

%% 10. CREATE WIDE / TEMPLATE-LIKE TABLE
wideNames = {'HN','PatientID','SeriesName','Measurement_Method'};

for L = 1:4
    lev = sprintf('L%d',L);

    wideNames = [wideNames,{ ... %#ok<AGROW>
        [lev '_HU_1'], ...
        [lev '_HU_2'], ...
        [lev '_HU_3'], ...
        [lev '_HU_mean'], ...
        [lev '_HU_SD_ROI'], ...
        [lev '_ROI_Area_mm2'], ...
        [lev '_Slice_Index_NIfTI'], ...
        [lev '_Valid'], ...
        [lev '_Abnormality'], ...
        [lev '_Auto_Status']}];
end

wideNames = [wideNames,{ ...
    'Mean_Valid_L1_L4_HU', ...
    'Number_of_Level_Means', ...
    'Review_Required', ...
    'Comments'}];

if isempty(wideRows)
    wideTable = cell2table(cell(0,numel(wideNames)), ...
        'VariableNames',wideNames);
else
    wideTable = cell2table(wideRows,'VariableNames',wideNames);
end

%% 11. RUN LOG
if isempty(runLogRows)
    runLog = cell2table(cell(0,numel(runLogVarNames)), ...
        'VariableNames',runLogVarNames);
else
    runLog = cell2table(runLogRows,'VariableNames',runLogVarNames);
end

%% 12. PARAMETERS / METHODS SHEET
parameterName = { ...
    'Skellytour_Mode'; ...
    'Skellytour_Model'; ...
    'Skellytour_Device'; ...
    'Skellytour_Trabecular_Label'; ...
    'BodyOpeningRadius_mm'; ...
    'BodyPresenceFraction'; ...
    'MinimumSlicePixels'; ...
    'nMeasurements'; ...
    'MeasurementOffsets'; ...
    'PrimarySlice'; ...
    'ROI_Source'; ...
    'AbnormalityAssessment'};

parameterValue = { ...
    'FULL prediction; NO --fast'; ...
    skellyModel; ...
    sprintf('GPU %d',gpuID); ...
    'Label 1'; ...
    num2str(bodyOpeningRadius_mm); ...
    num2str(bodyPresenceFraction); ...
    num2str(minSlicePixels); ...
    num2str(nMeasurements); ...
    mat2str(measurementOffsets(1:nMeasurements)); ...
    'Mid-vertebral-body axial slice'; ...
    ['TS L1-L4 x Skellytour label1 -> axial opening -> ' ...
     'largest 2-D component -> body-trabecular mask']; ...
    'Not performed; left for clinical review'};

parameterTable = table(parameterName,parameterValue, ...
    'VariableNames',{'Parameter','Value'});

%% 13. WRITE EXCEL
writetable(wideTable,excelFile,'Sheet','02_BONE_L1_L4_AUTO');
writetable(longTable,excelFile,'Sheet','Measurement_Long');
writetable(runLog,excelFile,'Sheet','Run_Log');
writetable(parameterTable,excelFile,'Sheet','Parameters');

fprintf('\n============================================================\n');
fprintf(' DONE: step2_Skel_TS\n');
fprintf(' Body masks + measurements completed.\n');
fprintf(' Excel: %s\n',excelFile);
fprintf('============================================================\n');

%% ========================================================================
% LOCAL FUNCTION: HN mapping
% ========================================================================
function hnMap = loadHNMap(refListFile,refSheet)

if ~isfile(refListFile)
    error('ไม่พบ HN reference file: %s',refListFile);
end

raw = readcell(refListFile,'Sheet',refSheet);

if isempty(raw) || size(raw,1)<2
    error('HN reference sheet %s ว่างหรืออ่านไม่ได้',refSheet);
end

headers = strtrim(string(raw(1,:)));
hnCol   = find(strcmpi(headers,'HN'),1);
codeCol = find(strcmpi(headers,'Code'),1);

if isempty(hnCol) || isempty(codeCol)
    error('Sheet %s ต้องมีคอลัมน์ HN และ Code',refSheet);
end

hnMap = containers.Map('KeyType','char','ValueType','char');

for r = 2:size(raw,1)

    codeValue = raw{r,codeCol};
    hnValue   = raw{r,hnCol};

    if isempty(codeValue) || (isnumeric(codeValue) && isnan(codeValue))
        continue;
    end

    codeStr = upper(strtrim(char(string(codeValue))));
    if isempty(codeStr) || ~startsWith(codeStr,'P')
        continue;
    end

    if isnumeric(hnValue)
        if isempty(hnValue) || isnan(hnValue)
            hnStr = '';
        else
            hnStr = sprintf('%07d',round(double(hnValue)));
        end
    else
        hnStr = strtrim(char(string(hnValue)));

        if ~isempty(regexp(hnStr,'^\d+$','once')) && numel(hnStr)<7
            hnStr = sprintf('%07d',str2double(hnStr));
        end
    end

    if isempty(hnStr)
        continue;
    end

    if ~isKey(hnMap,codeStr)
        hnMap(codeStr) = hnStr;
    end
end
end

%% ========================================================================
% LOCAL FUNCTION: find final Skellytour subseg output
% ========================================================================
function skellyFileInfo = findSkellyOutput(skellyOutDir)

skellyFileInfo = [];

candidates = dir(fullfile(skellyOutDir,'*_subseg_postprocessed.nii.gz'));

if isempty(candidates)
    candidates = dir(fullfile(skellyOutDir,'*subseg*.nii*'));
end

if isempty(candidates)
    return;
end

namesLower = lower(string({candidates.name}));

% Strong preference: final postprocessed subsegmentation
idx = find(contains(namesLower,'subseg_postprocessed'),1,'last');

if isempty(idx)
    idx = find(contains(namesLower,'postprocessed'),1,'last');
end

if isempty(idx)
    idx = 1;
end

skellyFileInfo = candidates(idx);
end

%% ========================================================================
% LOCAL FUNCTION: deterministic largest 2-D connected component
% Avoids bwareafilt warning when multiple components tie for first place.
% ========================================================================
function out = keepLargestComponent2D(BW,connectivity)

out = false(size(BW));

CC = bwconncomp(BW,connectivity);

if CC.NumObjects == 0
    return;
end

compSizes = cellfun(@numel,CC.PixelIdxList);
[~,idx] = max(compSizes);

out(CC.PixelIdxList{idx}) = true;
end
