clear; clc; close all;

%% ========================================================================
%  CUT AORTA 8 CM PIPELINE
%  - Uses TotalSegmentator aorta + lumbar vertebra masks
%  - Defines start point at mid-L1 axial slice
%  - Infers inferior direction from L2/L3/L4 position
%  - Keeps an 80-mm inferior aortic segment
%  - Saves one NIfTI mask per patient
%  - Exports summary table with HN mapping
%
%  NOTE:
%  The anatomical start reference is currently "mid-L1".
%  If the clinical team later specifies another reference point
%  (e.g. superior L1 endplate), change startReference accordingly.
% ========================================================================

%% 1. Paths / parameters
baseDataDir = 'F:\knomjeen_\File_non_contrast_nii1\';

refListFile = 'F:\knomjeen_\Ref_list_30AUG.xlsx';
refSheet    = 'Code';

excelFile = fullfile(baseDataDir, 'CT_Aorta_8cm_Summary.xlsx');

targetLength_mm = 80.0;
startReference  = 'MID_L1';  % current working definition

fprintf('=== CUT AORTA 8 CM PIPELINE ===\n');
fprintf('Base folder : %s\n', baseDataDir);
fprintf('Target      : %.1f mm inferior from %s\n\n', ...
    targetLength_mm, startReference);

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
                {vNames{idxCode}, vNames{idxHN}}, 'string');

            refT = readtable(refListFile, opts);

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
                refListFile, refSheet);
        end
    catch ME
        warning('อ่าน HN mapping ไม่สำเร็จ: %s', ME.message);
    end
else
    warning('ไม่พบ Ref_list file: %s', refListFile);
end

%% 3. Find TotalSegmentator output folders
dirInfo = dir(fullfile(baseDataDir, '*_output_highres'));
dirInfo = dirInfo([dirInfo.isdir]);

if isempty(dirInfo)
    error('ไม่พบ *_output_highres ใน %s', baseDataDir);
end

[~,ord] = sort({dirInfo.name});
dirInfo = dirInfo(ord);

fprintf('พบ TotalSegmentator output %d folders\n\n', numel(dirInfo));

%% 4. Result table
resultRows = {};

resultVarNames = { ...
    'HN', ...
    'PatientID', ...
    'SeriesName', ...
    'StartReference', ...
    'L1_CenterSlice', ...
    'InferiorDirection', ...
    'PixelSpacingX_mm', ...
    'PixelSpacingY_mm', ...
    'SliceSpacing_mm', ...
    'RequestedLength_mm', ...
    'RequestedSlices', ...
    'StartSlice', ...
    'EndSlice', ...
    'ActualSlabLength_mm', ...
    'AortaSlicesPresent', ...
    'AortaCoverageFraction', ...
    'AortaVoxelCount', ...
    'AortaSegmentVolume_mL', ...
    'OutputMaskFile', ...
    'Status', ...
    'Note'};

%% 5. Main loop
for p = 1:numel(dirInfo)

    targetDirName = dirInfo(p).name;
    patientDir = fullfile(baseDataDir, targetDirName);

    tokens = regexp(targetDirName, '^(P\d+)', 'tokens', 'once');
    if isempty(tokens)
        continue;
    end

    currentPatient = tokens{1};
    seriesBase = regexprep(targetDirName, '_output_highres$', '');

    fprintf('\n============================================================\n');
    fprintf('▶ Processing %s (%d/%d) | %s\n', ...
        currentPatient, p, numel(dirInfo), seriesBase);

    %% 5.1 HN lookup
    currentHN = '';
    if isKey(hnMap, currentPatient)
        currentHN = hnMap(currentPatient);
    end

    %% 5.2 Locate exact CT
    ctSearch = dir(fullfile(baseDataDir, [seriesBase, '.nii*']));
    ctSearch = ctSearch(~[ctSearch.isdir]);

    if isempty(ctSearch)
        resultRows(end+1,:) = { ...
            currentHN,currentPatient,seriesBase,startReference, ...
            NaN,NaN,NaN,NaN,NaN,targetLength_mm,NaN,NaN,NaN,NaN, ...
            NaN,NaN,NaN,NaN,'','FAILED','CT_NOT_FOUND'}; %#ok<SAGROW>
        fprintf('   -> CT_NOT_FOUND\n');
        continue;
    end

    exactNii = find(strcmpi({ctSearch.name}, [seriesBase,'.nii']),1);
    if ~isempty(exactNii)
        ctSearch = ctSearch(exactNii);
    else
        ctSearch = ctSearch(1);
    end

    ctFile = fullfile(ctSearch.folder, ctSearch.name);

    try
        CTinfo = niftiinfo(ctFile);
        volSize = CTinfo.ImageSize;

        if numel(volSize) < 3
            error('CT is not 3-D');
        end

        px = double(CTinfo.PixelDimensions(1));
        py = double(CTinfo.PixelDimensions(2));
        dz = double(CTinfo.PixelDimensions(3));
        nz = volSize(3);

    catch ME
        resultRows(end+1,:) = { ...
            currentHN,currentPatient,seriesBase,startReference, ...
            NaN,NaN,NaN,NaN,NaN,targetLength_mm,NaN,NaN,NaN,NaN, ...
            NaN,NaN,NaN,NaN,'','FAILED', ...
            ['CT_INFO_ERROR: ' ME.message]}; %#ok<SAGROW>
        fprintf('   -> CT_INFO_ERROR\n');
        continue;
    end

    %% 5.3 Load aorta + L1
    aortaFile = fullfile(patientDir, 'aorta.nii.gz');
    l1File    = fullfile(patientDir, 'vertebrae_L1.nii.gz');

    if ~isfile(aortaFile) || ~isfile(l1File)
        note = 'MISSING_AORTA_OR_L1_MASK';
        resultRows(end+1,:) = { ...
            currentHN,currentPatient,seriesBase,startReference, ...
            NaN,NaN,px,py,dz,targetLength_mm,NaN,NaN,NaN,NaN, ...
            NaN,NaN,NaN,NaN,'','FAILED',note}; %#ok<SAGROW>
        fprintf('   -> %s\n', note);
        continue;
    end

    try
        aortaMask = niftiread(aortaFile) > 0;
        l1Mask    = niftiread(l1File) > 0;
    catch ME
        note = ['MASK_READ_ERROR: ' ME.message];
        resultRows(end+1,:) = { ...
            currentHN,currentPatient,seriesBase,startReference, ...
            NaN,NaN,px,py,dz,targetLength_mm,NaN,NaN,NaN,NaN, ...
            NaN,NaN,NaN,NaN,'','FAILED',note}; %#ok<SAGROW>
        fprintf('   -> MASK_READ_ERROR\n');
        continue;
    end

    if ~isequal(size(aortaMask), volSize) || ~isequal(size(l1Mask), volSize)
        note = 'MASK_GEOMETRY_MISMATCH';
        resultRows(end+1,:) = { ...
            currentHN,currentPatient,seriesBase,startReference, ...
            NaN,NaN,px,py,dz,targetLength_mm,NaN,NaN,NaN,NaN, ...
            NaN,NaN,NaN,NaN,'','FAILED',note}; %#ok<SAGROW>
        fprintf('   -> %s\n', note);
        continue;
    end

    %% 5.4 Mid-L1 slice
    l1PerSlice = squeeze(any(any(l1Mask,1),2));
    l1Slices = find(l1PerSlice);

    if isempty(l1Slices)
        note = 'EMPTY_L1_MASK';
        resultRows(end+1,:) = { ...
            currentHN,currentPatient,seriesBase,startReference, ...
            NaN,NaN,px,py,dz,targetLength_mm,NaN,NaN,NaN,NaN, ...
            NaN,NaN,NaN,NaN,'','FAILED',note}; %#ok<SAGROW>
        fprintf('   -> %s\n', note);
        continue;
    end

    l1Center = round((min(l1Slices)+max(l1Slices))/2);

    %% 5.5 Infer inferior direction from lower lumbar levels
    inferiorDir = NaN;
    levelCandidates = {'L4','L3','L2'};

    for c = 1:numel(levelCandidates)
        lev = levelCandidates{c};
        f = fullfile(patientDir, sprintf('vertebrae_%s.nii.gz',lev));

        if ~isfile(f)
            continue;
        end

        try
            m = niftiread(f) > 0;
            if ~isequal(size(m), volSize)
                continue;
            end

            perSlice = squeeze(any(any(m,1),2));
            z = find(perSlice);

            if isempty(z)
                continue;
            end

            levCenter = round((min(z)+max(z))/2);
            d = sign(levCenter - l1Center);

            if d ~= 0
                inferiorDir = d;
                break;
            end
        catch
        end
    end

    if ~isfinite(inferiorDir)
        note = 'CANNOT_INFER_INFERIOR_DIRECTION';
        resultRows(end+1,:) = { ...
            currentHN,currentPatient,seriesBase,startReference, ...
            l1Center,NaN,px,py,dz,targetLength_mm,NaN,NaN,NaN,NaN, ...
            NaN,NaN,NaN,NaN,'','FAILED',note}; %#ok<SAGROW>
        fprintf('   -> %s\n', note);
        continue;
    end

    %% 5.6 Define 80-mm inferior slab
    % Number of slices whose nominal slab thickness is nearest 80 mm.
    nSlices = max(1, round(targetLength_mm / dz));
    sliceIdx = l1Center + inferiorDir*(0:nSlices-1);

    if any(sliceIdx < 1) || any(sliceIdx > nz)
        availableIdx = sliceIdx(sliceIdx >= 1 & sliceIdx <= nz);

        if isempty(availableIdx)
            actualLen = 0;
        else
            actualLen = numel(availableIdx) * dz;
        end

        note = sprintf('INSUFFICIENT_8CM_COVERAGE (available %.1f mm)', actualLen);

        resultRows(end+1,:) = { ...
            currentHN,currentPatient,seriesBase,startReference, ...
            l1Center,inferiorDir,px,py,dz,targetLength_mm,nSlices, ...
            NaN,NaN,actualLen,NaN,NaN,NaN,NaN,'', ...
            'EXCLUDE',note}; %#ok<SAGROW>

        fprintf('   -> EXCLUDE: %s\n', note);
        continue;
    end

    %% 5.7 Cut aorta mask to the 8-cm slab
    aorta8 = false(size(aortaMask));
    aorta8(:,:,sliceIdx) = aortaMask(:,:,sliceIdx);

    aortaVoxelCount = nnz(aorta8);
    voxelVol_mm3 = px * py * dz;
    aortaVol_mL = aortaVoxelCount * voxelVol_mm3 / 1000;

    aortaPerSlice = squeeze(any(any(aorta8,1),2));
    aortaPresentSlices = nnz(aortaPerSlice(sliceIdx));
    aortaCoverageFraction = aortaPresentSlices / nSlices;

    actualSlabLength = nSlices * dz;

    %% 5.8 Save NIfTI
    outDir = fullfile(patientDir, sprintf('%s_aorta_8cm_output', currentPatient));
    if ~exist(outDir,'dir')
        mkdir(outDir);
    end

    outBase = fullfile(outDir, sprintf('%s_aorta_8cm', currentPatient));
    outputMaskFile = [outBase '.nii.gz'];

    saveStatus = 'OK';
    note = '';

    try
        outInfo = niftiinfo(aortaFile);
        niftiwrite(uint8(aorta8), outBase, outInfo, 'Compressed', true);

        if ~isfile(outputMaskFile)
            chk = dir([outBase '*.nii*']);
            if ~isempty(chk)
                outputMaskFile = fullfile(chk(1).folder, chk(1).name);
            end
        end

    catch ME
        saveStatus = 'SAVE_FAILED';
        note = ME.message;
        outputMaskFile = '';
    end

    if aortaCoverageFraction < 0.90
        if isempty(note)
            note = sprintf('AORTA_MASK_GAPS: coverage fraction %.3f', ...
                aortaCoverageFraction);
        else
            note = sprintf('%s | AORTA_MASK_GAPS %.3f', ...
                note, aortaCoverageFraction);
        end

        if strcmp(saveStatus,'OK')
            saveStatus = 'QC_REVIEW';
        end
    end

    %% 5.9 Save result row
    resultRows(end+1,:) = { ...
        currentHN, ...
        currentPatient, ...
        seriesBase, ...
        startReference, ...
        l1Center, ...
        inferiorDir, ...
        px, ...
        py, ...
        dz, ...
        targetLength_mm, ...
        nSlices, ...
        sliceIdx(1), ...
        sliceIdx(end), ...
        actualSlabLength, ...
        aortaPresentSlices, ...
        aortaCoverageFraction, ...
        aortaVoxelCount, ...
        aortaVol_mL, ...
        outputMaskFile, ...
        saveStatus, ...
        note}; %#ok<SAGROW>

    fprintf(['   L1 mid=%d | dir=%+d | slices=%d (%d→%d) | ' ...
             'length=%.1f mm | aortaVol=%.2f mL | coverage=%.1f%% | %s\n'], ...
        l1Center,inferiorDir,nSlices,sliceIdx(1),sliceIdx(end), ...
        actualSlabLength,aortaVol_mL,100*aortaCoverageFraction,saveStatus);
end

%% 6. Export Excel
if isempty(resultRows)
    results = cell2table(cell(0,numel(resultVarNames)), ...
        'VariableNames',resultVarNames);
else
    results = cell2table(resultRows,'VariableNames',resultVarNames);
end

writetable(results,excelFile,'Sheet','Aorta_8cm');

%% 7. Parameters sheet
paramName = { ...
    'Target_Aorta_Length_mm'; ...
    'Start_Reference'; ...
    'Aorta_Source'; ...
    'Inferior_Direction_Method'; ...
    'Insufficient_Coverage_Action'};

paramValue = { ...
    targetLength_mm; ...
    startReference; ...
    'TotalSegmentator aorta.nii.gz'; ...
    'Direction from L1 toward the available lower lumbar level (L4/L3/L2)'; ...
    'EXCLUDE'};

params = table(paramName,paramValue, ...
    'VariableNames',{'Parameter','Value'});

writetable(params,excelFile,'Sheet','Parameters');

fprintf('\n====================================================================\n');
fprintf('DONE: Aorta 8-cm cutting pipeline\n');
fprintf('Excel: %s\n',excelFile);
fprintf('====================================================================\n');
