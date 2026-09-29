clear; clc; close all;

%% ========================================================================
%  ADRENAL QUANTIFICATION FROM TOTALSEGMENTATOR
%
%  Purpose:
%    Quantify LEFT and RIGHT adrenal glands separately using:
%      - TotalSegmentator adrenal_gland_left/right masks
%      - Original non-contrast CT in HU
%
%  Outputs per side:
%      - Volume (mL)
%      - Mean HU
%      - SD HU
%      - Voxel count
%      - Maximum axial cross-sectional area (mm^2) + slice index
%      - Geometry QC (mask touches image boundary)
%
%  IMPORTANT:
%    This is WHOLE-ADRENAL-GLAND quantification, NOT lesion-specific
%    segmentation. Lesion morphology / abnormality / diagnosis is NOT
%    assessed in this script.
% ========================================================================

%% 1. Paths
baseDataDir = 'F:\knomjeen_\File_non_contrast_nii1\';

refListFile = 'F:\knomjeen_\Ref_list_30AUG.xlsx';
refSheet    = 'Code';

excelFile = fullfile(baseDataDir, 'CT_Adrenal_TS_Quantification.xlsx');

fprintf('=== ADRENAL QUANTIFICATION FROM TOTALSEGMENTATOR ===\n');
fprintf('Base folder: %s\n\n', baseDataDir);

%% 2. Load P00x <-> HN mapping
hnMap = containers.Map('KeyType','char','ValueType','char');

if isfile(refListFile)
    try
        opts = detectImportOptions(refListFile, ...
            'Sheet', refSheet, ...
            'VariableNamingRule','preserve');

        vNames = opts.VariableNames;
        lowNames = lower(string(vNames));

        idxCode = find(contains(lowNames,'code'),1);
        idxHN   = find(strcmpi(lowNames,'hn') | contains(lowNames,'hn'),1);

        if ~isempty(idxCode) && ~isempty(idxHN)
            opts = setvartype(opts, ...
                {vNames{idxCode},vNames{idxHN}},'string');

            refT = readtable(refListFile,opts);

            codeVals = strtrim(string(refT.(vNames{idxCode})));
            hnVals   = strtrim(string(refT.(vNames{idxHN})));

            for r = 1:height(refT)
                if codeVals(r) ~= "" && hnVals(r) ~= ""
                    hnMap(char(codeVals(r))) = char(hnVals(r));
                end
            end

            fprintf('HN mapping loaded: %d records\n', hnMap.Count);
        else
            warning('ไม่พบ column Code/HN ใน %s sheet %s', ...
                refListFile,refSheet);
        end

    catch ME
        warning('อ่าน HN mapping ไม่สำเร็จ: %s',ME.message);
    end
else
    warning('ไม่พบ Ref_list file: %s',refListFile);
end

%% 3. Find TotalSegmentator output folders
dirInfo = dir(fullfile(baseDataDir,'*_output_highres'));
dirInfo = dirInfo([dirInfo.isdir]);

if isempty(dirInfo)
    error('ไม่พบ *_output_highres ใน %s',baseDataDir);
end

[~,ord] = sort({dirInfo.name});
dirInfo = dirInfo(ord);

fprintf('พบ TotalSegmentator output %d folders\n\n',numel(dirInfo));

%% 4. Result containers
longRows = {};
runLogRows = {};

longVarNames = { ...
    'HN', ...
    'PatientID', ...
    'SeriesName', ...
    'Side', ...
    'MaskFile', ...
    'VoxelCount', ...
    'Volume_mm3', ...
    'Volume_mL', ...
    'Mean_HU', ...
    'SD_HU', ...
    'Median_HU', ...
    'Min_HU', ...
    'Max_HU', ...
    'MaxAxialArea_mm2', ...
    'MaxAreaSlice', ...
    'TouchesVolumeBoundary', ...
    'Status', ...
    'Note'};

runLogVarNames = { ...
    'HN','PatientID','SeriesName','Stage','Status','Message'};

%% 5. Main loop
for p = 1:numel(dirInfo)

    targetDirName = dirInfo(p).name;
    patientDir    = fullfile(baseDataDir,targetDirName);

    tok = regexp(targetDirName,'^(P\d+)','tokens','once');
    if isempty(tok)
        continue;
    end

    pid = tok{1};
    seriesBase = regexprep(targetDirName,'_output_highres$','');

    fprintf('\n============================================================\n');
    fprintf('▶ Processing %s (%d/%d) | %s\n', ...
        pid,p,numel(dirInfo),seriesBase);

    %% 5.1 HN
    currentHN = '';
    if isKey(hnMap,pid)
        currentHN = hnMap(pid);
    end

    %% 5.2 Find exact original CT
    ctSearch = dir(fullfile(baseDataDir,[seriesBase,'.nii*']));
    ctSearch = ctSearch(~[ctSearch.isdir]);

    if isempty(ctSearch)
        msg = 'CT_NOT_FOUND';
        warning('%s | %s',pid,msg);
        runLogRows(end+1,:) = { ...
            currentHN,pid,seriesBase,'CT search','FAILED',msg}; %#ok<SAGROW>
        continue;
    end

    exactNii = find(strcmpi({ctSearch.name},[seriesBase,'.nii']),1);
    if ~isempty(exactNii)
        ctSearch = ctSearch(exactNii);
    else
        ctSearch = ctSearch(1);
    end

    ctFile = fullfile(ctSearch.folder,ctSearch.name);

    %% 5.3 Read CT
    try
        CT = double(niftiread(ctFile));
        ctInfo = niftiinfo(ctFile);
    catch ME
        msg = ['CT_READ_ERROR: ' ME.message];
        warning('%s | %s',pid,msg);
        runLogRows(end+1,:) = { ...
            currentHN,pid,seriesBase,'CT read','FAILED',msg}; %#ok<SAGROW>
        continue;
    end

    if ndims(CT) < 3
        msg = 'CT_NOT_3D';
        runLogRows(end+1,:) = { ...
            currentHN,pid,seriesBase,'Geometry','FAILED',msg}; %#ok<SAGROW>
        continue;
    end

    if numel(ctInfo.PixelDimensions) < 3
        msg = 'PIXEL_DIMENSIONS_NOT_3D';
        runLogRows(end+1,:) = { ...
            currentHN,pid,seriesBase,'Geometry','FAILED',msg}; %#ok<SAGROW>
        continue;
    end

    px = double(ctInfo.PixelDimensions(1));
    py = double(ctInfo.PixelDimensions(2));
    dz = double(ctInfo.PixelDimensions(3));

    voxelVol_mm3 = px * py * dz;
    pixelArea_mm2 = px * py;

    %% 5.4 LEFT / RIGHT loop
    sideNames = {'Left','Right'};
    maskNames = {'adrenal_gland_left.nii.gz', ...
                 'adrenal_gland_right.nii.gz'};

    for s = 1:2

        side = sideNames{s};
        maskFile = fullfile(patientDir,maskNames{s});

        if ~isfile(maskFile)
            longRows(end+1,:) = { ...
                currentHN,pid,seriesBase,side,maskFile, ...
                0,0,0,NaN,NaN,NaN,NaN,NaN,NaN,NaN, ...
                false,'MISSING_MASK','TotalSegmentator mask not found'}; %#ok<SAGROW>

            fprintf('   [%s] MISSING_MASK\n',side);
            continue;
        end

        try
            M = niftiread(maskFile) > 0;
        catch ME
            longRows(end+1,:) = { ...
                currentHN,pid,seriesBase,side,maskFile, ...
                0,0,0,NaN,NaN,NaN,NaN,NaN,NaN,NaN, ...
                false,'MASK_READ_FAILED',ME.message}; %#ok<SAGROW>

            fprintf('   [%s] MASK_READ_FAILED\n',side);
            continue;
        end

        if ~isequal(size(M),size(CT))
            longRows(end+1,:) = { ...
                currentHN,pid,seriesBase,side,maskFile, ...
                0,0,0,NaN,NaN,NaN,NaN,NaN,NaN,NaN, ...
                false,'GEOMETRY_MISMATCH','Mask and CT size differ'}; %#ok<SAGROW>

            fprintf('   [%s] GEOMETRY_MISMATCH\n',side);
            continue;
        end

        nVox = nnz(M);

        if nVox == 0
            longRows(end+1,:) = { ...
                currentHN,pid,seriesBase,side,maskFile, ...
                0,0,0,NaN,NaN,NaN,NaN,NaN,0,NaN, ...
                false,'EMPTY_MASK','No adrenal voxels detected'}; %#ok<SAGROW>

            fprintf('   [%s] EMPTY_MASK\n',side);
            continue;
        end

        %% 5.5 Whole-gland volume
        volume_mm3 = double(nVox) * voxelVol_mm3;
        volume_mL  = volume_mm3 / 1000;

        %% 5.6 Whole-gland HU statistics on original noncontrast CT
        hu = CT(M);
        hu = hu(isfinite(hu));

        if isempty(hu)
            meanHU   = NaN;
            sdHU     = NaN;
            medianHU = NaN;
            minHU    = NaN;
            maxHU    = NaN;
            statusText = 'NO_HU_VALUES';
            note = '';
        else
            meanHU   = mean(hu,'omitnan');
            sdHU     = std(hu,0,'omitnan');
            medianHU = median(hu,'omitnan');
            minHU    = min(hu);
            maxHU    = max(hu);
            statusText = 'OK';
            note = '';
        end

        %% 5.7 Maximum axial cross-sectional area
        pixPerSlice = squeeze(sum(sum(M,1),2));
        [maxPix,kMax] = max(pixPerSlice);

        maxArea_mm2 = double(maxPix) * pixelArea_mm2;

        %% 5.8 Geometry QC: does mask touch image boundary?
        touchesBoundary = false;

        if any(M(1,:,:),'all') || any(M(end,:,:),'all') || ...
           any(M(:,1,:),'all') || any(M(:,end,:),'all') || ...
           any(M(:,:,1),'all') || any(M(:,:,end),'all')
            touchesBoundary = true;

            if strcmp(statusText,'OK')
                statusText = 'QC_REVIEW';
            end

            note = 'Adrenal mask touches CT volume boundary; check scan coverage.';
        end

        %% 5.9 Save row
        longRows(end+1,:) = { ...
            currentHN, ...
            pid, ...
            seriesBase, ...
            side, ...
            maskFile, ...
            double(nVox), ...
            volume_mm3, ...
            volume_mL, ...
            meanHU, ...
            sdHU, ...
            medianHU, ...
            minHU, ...
            maxHU, ...
            maxArea_mm2, ...
            double(kMax), ...
            touchesBoundary, ...
            statusText, ...
            note}; %#ok<SAGROW>

        fprintf(['   [%s] Vol=%.2f mL | Mean=%.1f HU | SD=%.1f HU | ' ...
                 'MaxArea=%.1f mm^2 | slice=%d | %s\n'], ...
            side,volume_mL,meanHU,sdHU,maxArea_mm2,kMax,statusText);
    end

    runLogRows(end+1,:) = { ...
        currentHN,pid,seriesBase,'Patient','COMPLETED', ...
        'Left/right adrenal loop completed'}; %#ok<SAGROW>
end

%% 6. Build long table
if isempty(longRows)
    adrenalLong = cell2table(cell(0,numel(longVarNames)), ...
        'VariableNames',longVarNames);
else
    adrenalLong = cell2table(longRows, ...
        'VariableNames',longVarNames);
end

if isempty(runLogRows)
    runLog = cell2table(cell(0,numel(runLogVarNames)), ...
        'VariableNames',runLogVarNames);
else
    runLog = cell2table(runLogRows, ...
        'VariableNames',runLogVarNames);
end

writetable(adrenalLong,excelFile,'Sheet','Adrenal_Long');
writetable(runLog,excelFile,'Sheet','Run_Log');

%% 7. Wide table: one row per patient
patientList = unique(adrenalLong.PatientID,'stable');

wideRows = cell(numel(patientList),22);

for p = 1:numel(patientList)

    pid = patientList{p};
    idxP = strcmp(adrenalLong.PatientID,pid);
    subT = adrenalLong(idxP,:);

    currentHN = '';
    seriesName = '';

    if ~isempty(subT)
        currentHN = subT.HN{1};
        seriesName = subT.SeriesName{1};
    end

    row = cell(1,22);
    row{1} = currentHN;
    row{2} = pid;
    row{3} = seriesName;

    idxL = strcmp(subT.Side,'Left');
    idxR = strcmp(subT.Side,'Right');

    % Left
    if any(idxL)
        q = find(idxL,1);
        row{4}  = subT.Volume_mL(q);
        row{5}  = subT.Mean_HU(q);
        row{6}  = subT.SD_HU(q);
        row{7}  = subT.MaxAxialArea_mm2(q);
        row{8}  = subT.MaxAreaSlice(q);
        row{9}  = subT.VoxelCount(q);
        row{10} = subT.Status{q};
        row{11} = subT.Note{q};
    else
        row(4:11) = {NaN,NaN,NaN,NaN,NaN,NaN,'MISSING',''};
    end

    % Right
    if any(idxR)
        q = find(idxR,1);
        row{12} = subT.Volume_mL(q);
        row{13} = subT.Mean_HU(q);
        row{14} = subT.SD_HU(q);
        row{15} = subT.MaxAxialArea_mm2(q);
        row{16} = subT.MaxAreaSlice(q);
        row{17} = subT.VoxelCount(q);
        row{18} = subT.Status{q};
        row{19} = subT.Note{q};
    else
        row(12:19) = {NaN,NaN,NaN,NaN,NaN,NaN,'MISSING',''};
    end

    % Combined volume
    if isnumeric(row{4}) && isnumeric(row{12}) && ...
       isfinite(row{4}) && isfinite(row{12})
        row{20} = row{4} + row{12};
    else
        row{20} = NaN;
    end

    % Review flag
    leftOK  = ischar(row{10}) && strcmp(row{10},'OK');
    rightOK = ischar(row{18}) && strcmp(row{18},'OK');

    if leftOK && rightOK
        row{21} = 'No';
    else
        row{21} = 'Yes';
    end

    row{22} = 'Whole adrenal gland from TotalSegmentator; not lesion-specific.';

    wideRows(p,:) = row;
end

wideNames = { ...
    'HN','PatientID','SeriesName', ...
    'Left_Volume_mL','Left_Mean_HU','Left_SD_HU', ...
    'Left_MaxAxialArea_mm2','Left_MaxAreaSlice','Left_VoxelCount', ...
    'Left_Status','Left_Note', ...
    'Right_Volume_mL','Right_Mean_HU','Right_SD_HU', ...
    'Right_MaxAxialArea_mm2','Right_MaxAreaSlice','Right_VoxelCount', ...
    'Right_Status','Right_Note', ...
    'Both_Adrenal_Volume_mL', ...
    'Review_Required', ...
    'Method_Note'};

adrenalWide = cell2table(wideRows,'VariableNames',wideNames);
writetable(adrenalWide,excelFile,'Sheet','Adrenal_Wide');

%% 8. Parameters / method sheet
paramName = { ...
    'Segmentation_Source'; ...
    'CT_Source'; ...
    'Primary_Volume_Method'; ...
    'HU_Method'; ...
    'Area_Method'; ...
    'Clinical_Abnormality_Assessment'; ...
    'Important_Limitation'};

paramValue = { ...
    'TotalSegmentator adrenal_gland_left/right'; ...
    'Original non-contrast CT HU volume'; ...
    'Voxel count x PixelSpacingX x PixelSpacingY x SliceSpacing'; ...
    'All voxels inside whole-gland TotalSegmentator mask'; ...
    'Maximum axial cross-sectional area of whole-gland mask'; ...
    'Not performed by this script'; ...
    'Whole adrenal gland is quantified; adrenal lesion is not separately segmented.'};

paramT = table(paramName,paramValue, ...
    'VariableNames',{'Parameter','Value'});

writetable(paramT,excelFile,'Sheet','Parameters');

fprintf('\n====================================================================\n');
fprintf('DONE: TotalSegmentator adrenal quantification\n');
fprintf('Excel: %s\n',excelFile);
fprintf('====================================================================\n');
