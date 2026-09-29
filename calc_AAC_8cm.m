clear; clc; close all;

%% ========================================================================
%  AAC QUANTIFICATION FROM 8-CM AORTA MASK
%
%  Workflow:
%    Original CT (HU)
%       x
%    TotalSegmentator-derived 8-cm aorta mask
%       ->
%    Calcium threshold >= 130 HU
%       ->
%    Remove 2-D candidate lesions < 1.0 mm^2
%       ->
%    AAC presence / area / volume / Agatston / mean HU / max HU /
%    2-D lesion count / 3-D plaque-object count
%       ->
%    Save calcium NIfTI + Excel summary
%
%  IMPORTANT:
%  - 130 HU and 1 mm^2 are working defaults.
%  - Agatston is calculated slice-by-slice:
%       area x density factor
%       130-199 = 1
%       200-299 = 2
%       300-399 = 3
%       >=400   = 4
%  - Strict mode uses the 8-cm aorta mask exactly (no dilation).
% ========================================================================

%% 1. Paths / parameters
baseDataDir = 'F:\knomjeen_\File_non_contrast_nii1\';

aortaSummaryFile = fullfile(baseDataDir, 'CT_Aorta_8cm_Summary.xlsx');
aortaSummarySheet = 'Aorta_8cm';

outputExcel = fullfile(baseDataDir, 'CT_AAC_8cm_Quantification.xlsx');

calciumThreshold_HU = 130;
minLesionArea_mm2   = 1.0;

% Keep strict TotalSegmentator aorta mask for the first validation run.
% If later QC shows wall calcium is clipped by the aorta boundary,
% a small physical dilation can be evaluated separately.
aortaDilate_mm = 0.0;

fprintf('=== AAC 8-cm QUANTIFICATION ===\n');
fprintf('Calcium threshold  : >= %.0f HU\n', calciumThreshold_HU);
fprintf('Minimum lesion area: %.1f mm^2\n', minLesionArea_mm2);
fprintf('Aorta dilation     : %.1f mm\n\n', aortaDilate_mm);

%% 2. Read aorta-8cm summary
if ~isfile(aortaSummaryFile)
    error('ไม่พบไฟล์: %s', aortaSummaryFile);
end

opts = detectImportOptions(aortaSummaryFile, ...
    'Sheet', aortaSummarySheet, ...
    'VariableNamingRule','preserve');

% Keep identifiers as text where possible
textVars = intersect(opts.VariableNames, ...
    {'HN','PatientID','SeriesName','OutputMaskFile','Status','Note'});
if ~isempty(textVars)
    opts = setvartype(opts, textVars, 'string');
end

aortaT = readtable(aortaSummaryFile, opts);

requiredVars = {'HN','PatientID','SeriesName','OutputMaskFile','Status'};
for q = 1:numel(requiredVars)
    if ~ismember(requiredVars{q}, aortaT.Properties.VariableNames)
        error('Aorta summary ไม่มี column: %s', requiredVars{q});
    end
end

fprintf('พบทั้งหมด %d rows ใน Aorta_8cm summary\n', height(aortaT));

%% 3. Output containers
rows = {};

varNames = { ...
    'HN', ...
    'PatientID', ...
    'SeriesName', ...
    'Aorta8cm_Status', ...
    'CalciumThreshold_HU', ...
    'MinimumLesionArea_mm2', ...
    'PixelSpacingX_mm', ...
    'PixelSpacingY_mm', ...
    'SliceSpacing_mm', ...
    'AAC_Present', ...
    'AAC_TotalArea_mm2', ...
    'AAC_Volume_mm3', ...
    'AAC_Volume_mL', ...
    'AAC_AgatstonScore', ...
    'AAC_MeanHU', ...
    'AAC_MaxHU', ...
    'AAC_DensityFactorMean', ...
    'AAC_2D_LesionCount', ...
    'AAC_3D_PlaqueCount', ...
    'AAC_VoxelCount', ...
    'OutputCalciumMask', ...
    'Status', ...
    'Note'};

%% 4. Main loop
for r = 1:height(aortaT)

    HN = string(aortaT.HN(r));
    pid = string(aortaT.PatientID(r));
    seriesBase = string(aortaT.SeriesName(r));
    aortaStatus = upper(strtrim(string(aortaT.Status(r))));

    fprintf('\n============================================================\n');
    fprintf('▶ %s (%d/%d) | %s\n', pid, r, height(aortaT), seriesBase);

    % Skip cases already excluded at the 8-cm coverage stage
    if aortaStatus == "EXCLUDE" || aortaStatus == "FAILED"
        rows(end+1,:) = { ...
            char(HN),char(pid),char(seriesBase),char(aortaStatus), ...
            calciumThreshold_HU,minLesionArea_mm2, ...
            NaN,NaN,NaN, ...
            'Not assessed',0,0,0,0,NaN,NaN,NaN,0,0,0,'', ...
            'NOT_ANALYZED','Excluded/failed in aorta 8-cm stage'}; %#ok<SAGROW>

        fprintf('   -> Skip (%s)\n', aortaStatus);
        continue;
    end

    %% 4.1 Exact CT
    ctSearch = dir(fullfile(baseDataDir, [char(seriesBase), '.nii*']));
    ctSearch = ctSearch(~[ctSearch.isdir]);

    if isempty(ctSearch)
        rows(end+1,:) = { ...
            char(HN),char(pid),char(seriesBase),char(aortaStatus), ...
            calciumThreshold_HU,minLesionArea_mm2, ...
            NaN,NaN,NaN, ...
            'Not assessed',0,0,0,0,NaN,NaN,NaN,0,0,0,'', ...
            'FAILED','CT_NOT_FOUND'}; %#ok<SAGROW>
        fprintf('   -> CT_NOT_FOUND\n');
        continue;
    end

    exactNii = find(strcmpi({ctSearch.name}, [char(seriesBase),'.nii']),1);
    if ~isempty(exactNii)
        ctSearch = ctSearch(exactNii);
    else
        ctSearch = ctSearch(1);
    end

    ctFile = fullfile(ctSearch.folder,ctSearch.name);

    %% 4.2 Aorta 8-cm mask
    aortaMaskFile = char(string(aortaT.OutputMaskFile(r)));

    if isempty(aortaMaskFile) || ~isfile(aortaMaskFile)
        % Recovery by known folder convention
        patientDir = fullfile(baseDataDir, ...
            [char(seriesBase) '_output_highres']);
        alt = fullfile(patientDir, ...
            sprintf('%s_aorta_8cm_output',char(pid)), ...
            sprintf('%s_aorta_8cm.nii.gz',char(pid)));

        if isfile(alt)
            aortaMaskFile = alt;
        else
            rows(end+1,:) = { ...
                char(HN),char(pid),char(seriesBase),char(aortaStatus), ...
                calciumThreshold_HU,minLesionArea_mm2, ...
                NaN,NaN,NaN, ...
                'Not assessed',0,0,0,0,NaN,NaN,NaN,0,0,0,'', ...
                'FAILED','AORTA_8CM_MASK_NOT_FOUND'}; %#ok<SAGROW>
            fprintf('   -> AORTA_8CM_MASK_NOT_FOUND\n');
            continue;
        end
    end

    %% 4.3 Load CT + mask
    try
        CT = double(niftiread(ctFile));
        ctInfo = niftiinfo(ctFile);

        aorta8 = niftiread(aortaMaskFile) > 0;
        aortaInfo = niftiinfo(aortaMaskFile);

    catch ME
        rows(end+1,:) = { ...
            char(HN),char(pid),char(seriesBase),char(aortaStatus), ...
            calciumThreshold_HU,minLesionArea_mm2, ...
            NaN,NaN,NaN, ...
            'Not assessed',0,0,0,0,NaN,NaN,NaN,0,0,0,'', ...
            'FAILED',['NIFTI_READ_ERROR: ' ME.message]}; %#ok<SAGROW>
        fprintf('   -> NIFTI_READ_ERROR\n');
        continue;
    end

    if ~isequal(size(CT),size(aorta8))
        rows(end+1,:) = { ...
            char(HN),char(pid),char(seriesBase),char(aortaStatus), ...
            calciumThreshold_HU,minLesionArea_mm2, ...
            NaN,NaN,NaN, ...
            'Not assessed',0,0,0,0,NaN,NaN,NaN,0,0,0,'', ...
            'FAILED','GEOMETRY_MISMATCH'}; %#ok<SAGROW>
        fprintf('   -> GEOMETRY_MISMATCH\n');
        continue;
    end

    px = double(ctInfo.PixelDimensions(1));
    py = double(ctInfo.PixelDimensions(2));
    dz = double(ctInfo.PixelDimensions(3));

    pixelArea_mm2 = px * py;
    voxelVol_mm3  = px * py * dz;

    %% 4.4 Optional physical dilation of aorta mask
    analysisAortaMask = aorta8;

    if aortaDilate_mm > 0
        rPx = max(1,round(aortaDilate_mm/mean([px py])));
        se = strel('disk',rPx);
        for k = 1:size(analysisAortaMask,3)
            analysisAortaMask(:,:,k) = ...
                imdilate(analysisAortaMask(:,:,k),se);
        end
    end

    %% 4.5 HU threshold inside aorta mask
    rawCalcium = analysisAortaMask & (CT >= calciumThreshold_HU);

    %% 4.6 Per-slice lesion filtering + Agatston
    calciumMask = false(size(rawCalcium));

    totalArea_mm2  = 0;
    agatstonScore  = 0;
    lesionCount2D  = 0;

    nz = size(rawCalcium,3);

    for k = 1:nz

        thisSlice = rawCalcium(:,:,k);

        if ~any(thisSlice(:))
            continue;
        end

        CC = bwconncomp(thisSlice,8);

        for c = 1:CC.NumObjects

            pixIdx = CC.PixelIdxList{c};
            lesionArea_mm2 = numel(pixIdx) * pixelArea_mm2;

            % Minimum area requirement
            if lesionArea_mm2 < minLesionArea_mm2
                continue;
            end

            temp = false(size(thisSlice));
            temp(pixIdx) = true;
            calciumMask(:,:,k) = calciumMask(:,:,k) | temp;

            ctSlice = CT(:,:,k);
            lesionHU = ctSlice(pixIdx);
            maxHU = max(lesionHU);

            if maxHU < 200
                densityFactor = 1;
            elseif maxHU < 300
                densityFactor = 2;
            elseif maxHU < 400
                densityFactor = 3;
            else
                densityFactor = 4;
            end

            totalArea_mm2 = totalArea_mm2 + lesionArea_mm2;
            agatstonScore = agatstonScore + ...
                lesionArea_mm2 * densityFactor;

            lesionCount2D = lesionCount2D + 1;
        end
    end

    %% 4.7 Summary statistics
    nCalciumVox = nnz(calciumMask);

    if nCalciumVox > 0
        AAC_present = 'Yes';

        calciumHU = CT(calciumMask);

        meanHU = mean(calciumHU,'omitnan');
        maxHU  = max(calciumHU);

        volume_mm3 = nCalciumVox * voxelVol_mm3;
        volume_mL  = volume_mm3 / 1000;

        if totalArea_mm2 > 0
            densityFactorMean = agatstonScore / totalArea_mm2;
        else
            densityFactorMean = NaN;
        end

        % 3-D connected calcified objects
        CC3 = bwconncomp(calciumMask,26);
        plaqueCount3D = CC3.NumObjects;

        statusText = 'AAC_DETECTED';
        note = '';

    else
        AAC_present = 'No';
        meanHU = NaN;
        maxHU  = NaN;
        volume_mm3 = 0;
        volume_mL = 0;
        densityFactorMean = NaN;
        plaqueCount3D = 0;

        statusText = 'NO_AAC_DETECTED';
        note = sprintf('No >=%.0f HU lesion meeting %.1f mm^2 minimum area', ...
            calciumThreshold_HU,minLesionArea_mm2);
    end

    %% 4.8 Save calcium mask
    patientDir = fullfile(baseDataDir, ...
        [char(seriesBase) '_output_highres']);

    outDir = fullfile(patientDir, ...
        sprintf('%s_aorta_8cm_output',char(pid)));

    if ~exist(outDir,'dir')
        mkdir(outDir);
    end

    outBase = fullfile(outDir, ...
        sprintf('%s_AAC_8cm_%dHU', ...
        char(pid),round(calciumThreshold_HU)));

    outFile = [outBase '.nii.gz'];

    try
        niftiwrite(uint8(calciumMask),outBase,aortaInfo,'Compressed',true);

        if ~isfile(outFile)
            chk = dir([outBase '*.nii*']);
            if ~isempty(chk)
                outFile = fullfile(chk(1).folder,chk(1).name);
            end
        end
    catch ME
        if isempty(note)
            note = ['MASK_SAVE_ERROR: ' ME.message];
        else
            note = [note ' | MASK_SAVE_ERROR: ' ME.message];
        end
        outFile = '';
    end

    %% 4.9 Result row
    rows(end+1,:) = { ...
        char(HN), ...
        char(pid), ...
        char(seriesBase), ...
        char(aortaStatus), ...
        calciumThreshold_HU, ...
        minLesionArea_mm2, ...
        px, ...
        py, ...
        dz, ...
        AAC_present, ...
        totalArea_mm2, ...
        volume_mm3, ...
        volume_mL, ...
        agatstonScore, ...
        meanHU, ...
        maxHU, ...
        densityFactorMean, ...
        lesionCount2D, ...
        plaqueCount3D, ...
        nCalciumVox, ...
        outFile, ...
        statusText, ...
        note}; %#ok<SAGROW>

    fprintf(['   AAC=%s | Area=%.1f mm^2 | Vol=%.1f mm^3 | ' ...
             'Agatston=%.1f | Mean=%.1f | Max=%.1f HU | ' ...
             '2D lesions=%d | 3D plaques=%d\n'], ...
        AAC_present,totalArea_mm2,volume_mm3,agatstonScore, ...
        meanHU,maxHU,lesionCount2D,plaqueCount3D);
end

%% 5. Export Excel
if isempty(rows)
    outT = cell2table(cell(0,numel(varNames)), ...
        'VariableNames',varNames);
else
    outT = cell2table(rows,'VariableNames',varNames);
end

writetable(outT,outputExcel,'Sheet','AAC_8cm');

%% 6. Parameters / methodology sheet
paramName = { ...
    'Calcium_Threshold_HU'; ...
    'Minimum_Lesion_Area_mm2'; ...
    'Aorta_Mask_Source'; ...
    'Aorta_Dilation_mm'; ...
    'Connectivity_2D'; ...
    'Connectivity_3D'; ...
    'Agatston_Density_Factors'; ...
    'No_Calcium_Result'; ...
    'Important_QC_Note'};

paramValue = { ...
    calciumThreshold_HU; ...
    minLesionArea_mm2; ...
    'TotalSegmentator-derived 8-cm aorta mask'; ...
    aortaDilate_mm; ...
    '8-connectivity'; ...
    '26-connectivity'; ...
    '130-199=1; 200-299=2; 300-399=3; >=400=4'; ...
    'AAC_Present=No; Area/Volume/Agatston=0'; ...
    ['Strict aorta-mask analysis may clip calcification extending ' ...
     'outside the segmented aortic boundary; validate by overlay QC.']};

paramT = table(paramName,paramValue, ...
    'VariableNames',{'Parameter','Value'});

writetable(paramT,outputExcel,'Sheet','Parameters');

fprintf('\n====================================================================\n');
fprintf('DONE: AAC 8-cm quantification\n');
fprintf('Excel: %s\n',outputExcel);
fprintf('====================================================================\n');
