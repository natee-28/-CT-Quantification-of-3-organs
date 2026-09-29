clear; clc; close all;

%% ========================================================================
%  STEP 3: AORTA 8 CM FROM MID-L1 + AAC QUANTIFICATION
%  File: Step3_Aorta_8cm_midL1.m
%
%  Combined workflow:
%
%    Original non-contrast CT (HU)
%             +
%    TotalSegmentator aorta.nii.gz
%             +
%    TotalSegmentator vertebrae_L1-L4
%             |
%             v
%    Find MID-L1 axial slice
%             |
%    Infer inferior direction from L2/L3/L4
%             |
%    Cut a predefined 80-mm inferior aortic segment
%             |
%       +-----+---------------------------------------+
%       |                                             |
%       v                                             v
%    Save 8-cm aorta mask                       HU >= 130
%                                                     |
%                                          2-D lesion area >= 1 mm^2
%                                                     |
%                                                     v
%                                   AAC area / volume / Agatston /
%                                   mean HU / max HU / plaque counts
%                                                     |
%                                                     v
%                                          Save AAC NIfTI mask
%
%  Outputs:
%    - <P00x>_aorta_8cm.nii.gz
%    - <P00x>_AAC_8cm_130HU.nii.gz
%    - Excel workbook:
%         01_Aorta_8cm
%         02_AAC_8cm
%         03_Combined
%         Run_Log
%         Parameters
%
%  IMPORTANT:
%    - Current anatomical reference = MID-L1.
%    - Current AAC threshold = >=130 HU.
%    - Current minimum 2-D calcified lesion area = 1.0 mm^2.
%    - Strict TotalSegmentator aorta boundary is used (no dilation).
%    - Clinical interpretation / abnormality classification is NOT done here.
% ========================================================================

%% 1. USER SETTINGS
baseDataDir = 'F:\knomjeen_\File_non_contrast_nii\';

if ~isfolder(baseDataDir)
    fallbackDir = 'F:\knomjeen_\File_non_contrast_nii1\';
    if isfolder(fallbackDir)
        baseDataDir = fallbackDir;
    else
        error('ไม่พบทั้ง File_non_contrast_nii และ File_non_contrast_nii1');
    end
end

refListFile = 'F:\knomjeen_\Ref_list_30AUG.xlsx';
refSheet    = 'Code';

excelFile = fullfile(baseDataDir, 'CT_Step3_Aorta_8cm_AAC.xlsx');

targetLength_mm = 80.0;
startReference  = 'MID_L1';

calciumThreshold_HU = 130;
minLesionArea_mm2   = 1.0;
aortaDilate_mm = 0.0;

minAortaCoverageFraction = 0.90;

saveAorta8Mask = true;
saveAACMask    = true;

fprintf('\n============================================================\n');
fprintf(' STEP 3: AORTA 8 CM FROM MID-L1 + AAC\n');
fprintf(' Base folder             : %s\n',baseDataDir);
fprintf(' Start reference         : %s\n',startReference);
fprintf(' Target length           : %.1f mm\n',targetLength_mm);
fprintf(' Calcium threshold       : >= %.0f HU\n',calciumThreshold_HU);
fprintf(' Minimum lesion area     : %.1f mm^2\n',minLesionArea_mm2);
fprintf(' Aorta dilation          : %.1f mm\n',aortaDilate_mm);
fprintf('============================================================\n');

%% 2. HN MAPPING
hnMap = loadHNMap(refListFile,refSheet);
fprintf('HN mapping loaded: %d records\n',hnMap.Count);

%% 3. FIND TOTALSEGMENTATOR OUTPUT FOLDERS
dirInfo = dir(fullfile(baseDataDir,'*_output_highres'));
dirInfo = dirInfo([dirInfo.isdir]);

if isempty(dirInfo)
    error('ไม่พบ *_output_highres ใน %s',baseDataDir);
end

[~,sortIdx] = sort({dirInfo.name});
dirInfo = dirInfo(sortIdx);

fprintf('TotalSegmentator output folders: %d\n',numel(dirInfo));

%% 4. RESULT CONTAINERS
aortaRows = {};
aacRows   = {};
combinedRows = {};
runLogRows = {};

aortaVarNames = { ...
    'HN','PatientID','SeriesName','StartReference', ...
    'L1_CenterSlice','InferiorDirection', ...
    'PixelSpacingX_mm','PixelSpacingY_mm','SliceSpacing_mm', ...
    'RequestedLength_mm','RequestedSlices','StartSlice','EndSlice', ...
    'ActualSlabLength_mm','AortaSlicesPresent','AortaCoverageFraction', ...
    'AortaVoxelCount','AortaSegmentVolume_mL', ...
    'Aorta8cmMaskFile','Status','Note'};

aacVarNames = { ...
    'HN','PatientID','SeriesName','Aorta8cm_Status', ...
    'CalciumThreshold_HU','MinimumLesionArea_mm2', ...
    'AAC_Present','AAC_TotalArea_mm2','AAC_Volume_mm3','AAC_Volume_mL', ...
    'AAC_AgatstonScore','AAC_MeanHU','AAC_MaxHU', ...
    'AAC_DensityFactorMean','AAC_2D_LesionCount','AAC_3D_PlaqueCount', ...
    'AAC_VoxelCount','AAC_MaskFile','Status','Note'};

combinedVarNames = { ...
    'HN','PatientID','SeriesName', ...
    'L1_CenterSlice','StartSlice','EndSlice','ActualSlabLength_mm', ...
    'AortaCoverageFraction','AortaSegmentVolume_mL', ...
    'AAC_Present','AAC_TotalArea_mm2','AAC_Volume_mm3','AAC_Volume_mL', ...
    'AAC_AgatstonScore','AAC_MeanHU','AAC_MaxHU', ...
    'AAC_2D_LesionCount','AAC_3D_PlaqueCount', ...
    'Final_Status','Review_Required','Note'};

runLogVarNames = {'HN','PatientID','SeriesName','Stage','Status','Message'};

%% 5. MAIN LOOP
for p = 1:numel(dirInfo)

    targetDirName = dirInfo(p).name;
    patientDir = fullfile(baseDataDir,targetDirName);

    tok = regexp(targetDirName,'^(P\d+)','tokens','once');
    if isempty(tok)
        continue;
    end

    pid = tok{1};
    seriesBase = regexprep(targetDirName,'_output_highres$','');

    if isKey(hnMap,pid)
        HN = hnMap(pid);
    else
        HN = '';
    end

    fprintf('\n============================================================\n');
    fprintf('▶ Processing %s (%d/%d) | HN=%s | %s\n', ...
        pid,p,numel(dirInfo),HN,seriesBase);

    %% 5.1 EXACT CT NIfTI
    ctSearch = dir(fullfile(baseDataDir,[seriesBase,'.nii*']));
    ctSearch = ctSearch(~[ctSearch.isdir]);

    if isempty(ctSearch)
        msg = 'CT_NOT_FOUND';
        runLogRows(end+1,:) = {HN,pid,seriesBase,'CT search','FAILED',msg}; %#ok<SAGROW>
        fprintf('   -> %s\n',msg);
        continue;
    end

    exactNii = find(strcmpi({ctSearch.name},[seriesBase,'.nii']),1);
    if ~isempty(exactNii)
        ctSearch = ctSearch(exactNii);
    else
        ctSearch = ctSearch(1);
    end

    ctFile = fullfile(ctSearch.folder,ctSearch.name);

    try
        CT = double(niftiread(ctFile));
        ctInfo = niftiinfo(ctFile);
    catch ME
        msg = ['CT_READ_ERROR: ' ME.message];
        runLogRows(end+1,:) = {HN,pid,seriesBase,'CT read','FAILED',msg}; %#ok<SAGROW>
        fprintf('   -> CT_READ_ERROR\n');
        continue;
    end

    if ndims(CT) < 3 || numel(ctInfo.PixelDimensions) < 3
        msg = 'CT_NOT_VALID_3D';
        runLogRows(end+1,:) = {HN,pid,seriesBase,'Geometry','FAILED',msg}; %#ok<SAGROW>
        fprintf('   -> %s\n',msg);
        continue;
    end

    px = double(ctInfo.PixelDimensions(1));
    py = double(ctInfo.PixelDimensions(2));
    dz = double(ctInfo.PixelDimensions(3));
    nz = size(CT,3);

    voxelVol_mm3  = px*py*dz;
    pixelArea_mm2 = px*py;

    %% 5.2 LOAD AORTA + L1
    aortaFile = fullfile(patientDir,'aorta.nii.gz');
    l1File    = fullfile(patientDir,'vertebrae_L1.nii.gz');

    if ~isfile(aortaFile) || ~isfile(l1File)
        msg = 'MISSING_AORTA_OR_L1_MASK';
        runLogRows(end+1,:) = {HN,pid,seriesBase,'TS masks','FAILED',msg}; %#ok<SAGROW>
        fprintf('   -> %s\n',msg);
        continue;
    end

    try
        aortaMask = niftiread(aortaFile) > 0;
        l1Mask    = niftiread(l1File) > 0;
    catch ME
        msg = ['MASK_READ_ERROR: ' ME.message];
        runLogRows(end+1,:) = {HN,pid,seriesBase,'TS mask read','FAILED',msg}; %#ok<SAGROW>
        fprintf('   -> MASK_READ_ERROR\n');
        continue;
    end

    if ~isequal(size(aortaMask),size(CT)) || ~isequal(size(l1Mask),size(CT))
        msg = 'TS_MASK_GEOMETRY_MISMATCH';
        runLogRows(end+1,:) = {HN,pid,seriesBase,'Geometry','FAILED',msg}; %#ok<SAGROW>
        fprintf('   -> %s\n',msg);
        continue;
    end

    %% 5.3 MID-L1
    l1PerSlice = squeeze(any(any(l1Mask,1),2));
    l1Slices = find(l1PerSlice);

    if isempty(l1Slices)
        msg = 'EMPTY_L1_MASK';
        runLogRows(end+1,:) = {HN,pid,seriesBase,'L1','FAILED',msg}; %#ok<SAGROW>
        fprintf('   -> %s\n',msg);
        continue;
    end

    l1Center = round((min(l1Slices)+max(l1Slices))/2);

    %% 5.4 INFER INFERIOR DIRECTION
    inferiorDir = NaN;
    inferSource = '';

    for lev = {'L4','L3','L2'}

        levName = lev{1};
        levFile = fullfile(patientDir,sprintf('vertebrae_%s.nii.gz',levName));

        if ~isfile(levFile)
            continue;
        end

        try
            m = niftiread(levFile) > 0;

            if ~isequal(size(m),size(CT))
                continue;
            end

            perSlice = squeeze(any(any(m,1),2));
            zList = find(perSlice);

            if isempty(zList)
                continue;
            end

            levCenter = round((min(zList)+max(zList))/2);
            d = sign(levCenter-l1Center);

            if d ~= 0
                inferiorDir = d;
                inferSource = levName;
                break;
            end
        catch
        end
    end

    if ~isfinite(inferiorDir)
        msg = 'CANNOT_INFER_INFERIOR_DIRECTION';
        runLogRows(end+1,:) = {HN,pid,seriesBase,'Direction','FAILED',msg}; %#ok<SAGROW>
        fprintf('   -> %s\n',msg);
        continue;
    end

    %% 5.5 DEFINE 80-MM SLAB
    nSlices = max(1,round(targetLength_mm/dz));
    sliceIdx = l1Center + inferiorDir*(0:nSlices-1);

    if any(sliceIdx < 1) || any(sliceIdx > nz)

        validIdx = sliceIdx(sliceIdx>=1 & sliceIdx<=nz);
        availableLen = numel(validIdx)*dz;

        aortaStatus = 'EXCLUDE';
        aortaNote = sprintf( ...
            'INSUFFICIENT_8CM_COVERAGE; available %.1f mm',availableLen);

        aortaRows(end+1,:) = { ...
            HN,pid,seriesBase,startReference,l1Center,inferiorDir, ...
            px,py,dz,targetLength_mm,nSlices,NaN,NaN,availableLen, ...
            NaN,NaN,NaN,NaN,'',aortaStatus,aortaNote}; %#ok<SAGROW>

        aacRows(end+1,:) = { ...
            HN,pid,seriesBase,aortaStatus, ...
            calciumThreshold_HU,minLesionArea_mm2, ...
            'Not assessed',0,0,0,0,NaN,NaN,NaN,0,0,0,'', ...
            'NOT_ANALYZED','Insufficient 8-cm aortic coverage'}; %#ok<SAGROW>

        combinedRows(end+1,:) = { ...
            HN,pid,seriesBase,l1Center,NaN,NaN,availableLen, ...
            NaN,NaN,'Not assessed',0,0,0,0,NaN,NaN,0,0, ...
            'EXCLUDE','Yes',aortaNote}; %#ok<SAGROW>

        fprintf('   -> EXCLUDE: %s\n',aortaNote);
        continue;
    end

    actualSlabLength = nSlices*dz;

    %% 5.6 CUT AORTA TO 8-CM SLAB
    aorta8 = false(size(aortaMask));
    aorta8(:,:,sliceIdx) = aortaMask(:,:,sliceIdx);

    aortaVoxelCount = nnz(aorta8);
    aortaVol_mL = aortaVoxelCount*voxelVol_mm3/1000;

    presentPerSlice = squeeze(any(any(aorta8,1),2));
    aortaPresentSlices = nnz(presentPerSlice(sliceIdx));
    aortaCoverageFraction = aortaPresentSlices/nSlices;

    if aortaCoverageFraction < minAortaCoverageFraction
        aortaStatus = 'QC_REVIEW';
        aortaNote = sprintf('AORTA_MASK_GAPS; coverage %.3f', ...
            aortaCoverageFraction);
    else
        aortaStatus = 'OK';
        aortaNote = '';
    end

    %% 5.7 OUTPUT FOLDER
    outDir = fullfile(patientDir,sprintf('%s_aorta_8cm_output',pid));
    if ~exist(outDir,'dir')
        mkdir(outDir);
    end

    %% 5.8 SAVE 8-CM AORTA NIfTI
    aortaOutBase = fullfile(outDir,sprintf('%s_aorta_8cm',pid));
    aortaOutFile = [aortaOutBase '.nii.gz'];

    if saveAorta8Mask
        try
            aortaInfo = niftiinfo(aortaFile);

            if isfile(aortaOutFile)
                delete(aortaOutFile);
            end

            niftiwrite(uint8(aorta8),aortaOutBase,aortaInfo,'Compressed',true);

            if ~isfile(aortaOutFile)
                chk = dir([aortaOutBase '*.nii*']);
                if ~isempty(chk)
                    aortaOutFile = fullfile(chk(1).folder,chk(1).name);
                end
            end
        catch ME
            aortaStatus = 'SAVE_FAILED';
            aortaNote = appendNote(aortaNote,['AORTA_SAVE_ERROR: ' ME.message]);
            aortaOutFile = '';
        end
    end

    aortaRows(end+1,:) = { ...
        HN,pid,seriesBase,startReference,l1Center,inferiorDir, ...
        px,py,dz,targetLength_mm,nSlices,sliceIdx(1),sliceIdx(end), ...
        actualSlabLength,aortaPresentSlices,aortaCoverageFraction, ...
        double(aortaVoxelCount),aortaVol_mL,aortaOutFile, ...
        aortaStatus,aortaNote}; %#ok<SAGROW>

    %% 5.9 OPTIONAL AORTA DILATION FOR AAC
    analysisAortaMask = aorta8;

    if aortaDilate_mm > 0
        rPx = max(1,round(aortaDilate_mm/mean([px py])));
        se = strel('disk',rPx,0);

        for z = sliceIdx
            analysisAortaMask(:,:,z) = imdilate(analysisAortaMask(:,:,z),se);
        end
    end

    %% 5.10 AAC DETECTION >=130 HU
    rawCalcium = analysisAortaMask & (CT >= calciumThreshold_HU);
    calciumMask = false(size(rawCalcium));

    totalArea_mm2 = 0;
    agatstonScore = 0;
    lesionCount2D = 0;

    for z = sliceIdx

        thisSlice = rawCalcium(:,:,z);

        if ~any(thisSlice(:))
            continue;
        end

        CC = bwconncomp(thisSlice,8);

        for c = 1:CC.NumObjects

            pixIdx = CC.PixelIdxList{c};
            lesionArea_mm2 = numel(pixIdx)*pixelArea_mm2;

            if lesionArea_mm2 < minLesionArea_mm2
                continue;
            end

            keep = false(size(thisSlice));
            keep(pixIdx) = true;
            calciumMask(:,:,z) = calciumMask(:,:,z) | keep;

            ctSlice = CT(:,:,z);
            lesionHU = ctSlice(pixIdx);
            peakHU = max(lesionHU);

            if peakHU < 200
                densityFactor = 1;
            elseif peakHU < 300
                densityFactor = 2;
            elseif peakHU < 400
                densityFactor = 3;
            else
                densityFactor = 4;
            end

            totalArea_mm2 = totalArea_mm2 + lesionArea_mm2;
            agatstonScore = agatstonScore + lesionArea_mm2*densityFactor;
            lesionCount2D = lesionCount2D + 1;
        end
    end

    %% 5.11 AAC SUMMARY
    nCalciumVox = nnz(calciumMask);

    if nCalciumVox > 0

        AAC_present = 'Yes';

        calciumHU = CT(calciumMask);
        meanHU = mean(calciumHU,'omitnan');
        maxHU  = max(calciumHU);

        volume_mm3 = nCalciumVox*voxelVol_mm3;
        volume_mL  = volume_mm3/1000;

        densityFactorMean = agatstonScore/totalArea_mm2;

        CC3 = bwconncomp(calciumMask,26);
        plaqueCount3D = CC3.NumObjects;

        aacStatus = 'AAC_DETECTED';
        aacNote = '';

    else

        AAC_present = 'No';
        meanHU = NaN;
        maxHU  = NaN;
        volume_mm3 = 0;
        volume_mL = 0;
        densityFactorMean = NaN;
        plaqueCount3D = 0;

        aacStatus = 'NO_AAC_DETECTED';
        aacNote = sprintf( ...
            'No >=%.0f HU lesion meeting %.1f mm^2 minimum area', ...
            calciumThreshold_HU,minLesionArea_mm2);
    end

    %% 5.12 SAVE AAC MASK
    aacOutBase = fullfile(outDir, ...
        sprintf('%s_AAC_8cm_%dHU',pid,round(calciumThreshold_HU)));
    aacOutFile = [aacOutBase '.nii.gz'];

    if saveAACMask
        try
            aortaInfo = niftiinfo(aortaFile);

            if isfile(aacOutFile)
                delete(aacOutFile);
            end

            niftiwrite(uint8(calciumMask),aacOutBase,aortaInfo,'Compressed',true);

            if ~isfile(aacOutFile)
                chk = dir([aacOutBase '*.nii*']);
                if ~isempty(chk)
                    aacOutFile = fullfile(chk(1).folder,chk(1).name);
                end
            end

        catch ME
            aacStatus = 'SAVE_FAILED';
            aacNote = appendNote(aacNote,['AAC_SAVE_ERROR: ' ME.message]);
            aacOutFile = '';
        end
    end

    aacRows(end+1,:) = { ...
        HN,pid,seriesBase,aortaStatus, ...
        calciumThreshold_HU,minLesionArea_mm2, ...
        AAC_present,totalArea_mm2,volume_mm3,volume_mL, ...
        agatstonScore,meanHU,maxHU,densityFactorMean, ...
        lesionCount2D,plaqueCount3D,double(nCalciumVox), ...
        aacOutFile,aacStatus,aacNote}; %#ok<SAGROW>

    %% 5.13 COMBINED RESULT
    finalStatus = 'OK';
    reviewRequired = 'No';
    combinedNote = '';

    if strcmp(aortaStatus,'QC_REVIEW') || strcmp(aacStatus,'SAVE_FAILED') || ...
            strcmp(aortaStatus,'SAVE_FAILED')
        finalStatus = 'QC_REVIEW';
        reviewRequired = 'Yes';
    end

    combinedNote = appendNote(combinedNote,aortaNote);
    combinedNote = appendNote(combinedNote,aacNote);

    combinedRows(end+1,:) = { ...
        HN,pid,seriesBase,l1Center,sliceIdx(1),sliceIdx(end), ...
        actualSlabLength,aortaCoverageFraction,aortaVol_mL, ...
        AAC_present,totalArea_mm2,volume_mm3,volume_mL, ...
        agatstonScore,meanHU,maxHU,lesionCount2D,plaqueCount3D, ...
        finalStatus,reviewRequired,combinedNote}; %#ok<SAGROW>

    fprintf(['   Aorta: L1mid=%d | dir=%+d (%s) | %d→%d | %.1f mm | ' ...
             'coverage=%.1f%% | Vol=%.2f mL\n'], ...
        l1Center,inferiorDir,inferSource,sliceIdx(1),sliceIdx(end), ...
        actualSlabLength,100*aortaCoverageFraction,aortaVol_mL);

    fprintf(['   AAC  : %s | Area=%.1f mm^2 | Vol=%.1f mm^3 | ' ...
             'Agatston=%.1f | Mean=%.1f | Max=%.1f HU | plaques=%d\n'], ...
        AAC_present,totalArea_mm2,volume_mm3,agatstonScore, ...
        meanHU,maxHU,plaqueCount3D);

    runLogRows(end+1,:) = { ...
        HN,pid,seriesBase,'Patient','COMPLETED', ...
        'Aorta 8-cm + AAC pipeline completed'}; %#ok<SAGROW>
end

%% 6. TABLES
aortaTable = rowsToTable(aortaRows,aortaVarNames);
aacTable   = rowsToTable(aacRows,aacVarNames);
combinedTable = rowsToTable(combinedRows,combinedVarNames);
runLogTable   = rowsToTable(runLogRows,runLogVarNames);

%% 7. PARAMETERS / METHODS
paramName = { ...
    'Start_Reference'; ...
    'Target_Aorta_Length_mm'; ...
    'Inferior_Direction_Method'; ...
    'Aorta_Source'; ...
    'Minimum_Aorta_Coverage_Fraction'; ...
    'Calcium_Threshold_HU'; ...
    'Minimum_Calcified_Lesion_Area_mm2'; ...
    'Aorta_Dilation_mm'; ...
    'AAC_2D_Connectivity'; ...
    'AAC_3D_Connectivity'; ...
    'Agatston_Density_Factors'; ...
    'No_Calcium_Result'; ...
    'Clinical_Abnormality_Assessment'; ...
    'Important_QC_Note'};

paramValue = { ...
    startReference; ...
    num2str(targetLength_mm); ...
    'Direction from L1 toward available lower lumbar level (L4/L3/L2)'; ...
    'TotalSegmentator aorta.nii.gz'; ...
    num2str(minAortaCoverageFraction); ...
    num2str(calciumThreshold_HU); ...
    num2str(minLesionArea_mm2); ...
    num2str(aortaDilate_mm); ...
    '8-connectivity'; ...
    '26-connectivity'; ...
    '130-199=1; 200-299=2; 300-399=3; >=400=4'; ...
    'AAC_Present=No; Area/Volume/Agatston=0'; ...
    'Not performed by this script'; ...
    ['Strict TS aorta boundary may clip calcification at the aortic wall; ' ...
     'validate representative overlays before final analysis.']};

parameterTable = table(paramName,paramValue, ...
    'VariableNames',{'Parameter','Value'});

%% 8. WRITE EXCEL
writetable(aortaTable,excelFile,'Sheet','01_Aorta_8cm');
writetable(aacTable,excelFile,'Sheet','02_AAC_8cm');
writetable(combinedTable,excelFile,'Sheet','03_Combined');
writetable(runLogTable,excelFile,'Sheet','Run_Log');
writetable(parameterTable,excelFile,'Sheet','Parameters');

fprintf('\n============================================================\n');
fprintf(' DONE: Step3_Aorta_8cm_midL1\n');
fprintf(' Excel: %s\n',excelFile);
fprintf('============================================================\n');

%% ========================================================================
% LOCAL FUNCTION: HN MAPPING
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
% LOCAL FUNCTION: APPEND NOTE
% ========================================================================
function out = appendNote(existing,newText)

existing = char(string(existing));
newText  = char(string(newText));

if isempty(strtrim(newText))
    out = existing;
elseif isempty(strtrim(existing))
    out = newText;
else
    out = [existing ' | ' newText];
end
end

%% ========================================================================
% LOCAL FUNCTION: CELL ROWS -> TABLE
% ========================================================================
function T = rowsToTable(rows,varNames)

if isempty(rows)
    T = cell2table(cell(0,numel(varNames)), ...
        'VariableNames',varNames);
else
    T = cell2table(rows,'VariableNames',varNames);
end
end
