 clear; clc; close all;

%% ========================================================================
%  STEP 4: MASTER QC — BONE + AORTA/AAC + ADRENAL
%  File: Step4_Master_QC.m
%
%  Purpose:
%    Merge the three automated quantitative outputs into ONE row per PatientID
%    and assign an explicit cohort-level QC status:
%
%      PASS    = all 3 components available and automated QC passed
%      REVIEW  = result may be usable, but manual QC / reconciliation is needed
%      EXCLUDE = explicit protocol exclusion from the aorta 8-cm workflow
%
%  IMPORTANT PHILOSOPHY:
%    "Automation measures. QC flags. Clinical interpretation stays with
%     the clinical team."
%
%  Input workbooks:
%    1) CT_Trabecular_L1_L4_step2_Skel_TS*.xlsx
%       sheet: 02_BONE_L1_L4_AUTO
%
%    2) CT_Step3_Aorta_8cm_AAC.xlsx
%       sheet: 03_Combined
%
%    3) CT_Adrenal_TS_Quantification.xlsx
%       sheet: Adrenal_Wide
%
%  Output:
%    CT_Master_QC.xlsx
%
%  Sheets:
%    - Master_QC
%    - QC_Summary
%    - Reason_Counts
%    - Duplicate_Series
%    - Parameters
%
%  Duplicate-series policy:
%    - NEVER silently pretend duplicates do not exist.
%    - If Adrenal has exactly one series, that SeriesName becomes the
%      canonical series and is used to select matching Bone/Aorta rows.
%    - If no exact match exists, Standard is preferred over ThinSlice,
%      then the first available row is selected.
%    - Any duplicate source rows still trigger DUPLICATE_SERIES -> REVIEW
%      (unless the patient is already EXCLUDE by protocol).
%
% ========================================================================

%% 1. PATHS
baseDataDir = 'F:\knomjeen_\File_non_contrast_nii\';

if ~isfolder(baseDataDir)
    fallbackDir = 'F:\knomjeen_\File_non_contrast_nii1\';
    if isfolder(fallbackDir)
        baseDataDir = fallbackDir;
    else
        error('ไม่พบทั้ง File_non_contrast_nii และ File_non_contrast_nii1');
    end
end

boneFile = findLatestFile(baseDataDir, ...
    'CT_Trabecular_L1_L4_step2_Skel_TS*.xlsx');

aortaFile = fullfile(baseDataDir,'CT_Step3_Aorta_8cm_AAC.xlsx');
adrenalFile = fullfile(baseDataDir,'CT_Adrenal_TS_Quantification.xlsx');

if ~isfile(aortaFile)
    error('ไม่พบ Aorta workbook: %s',aortaFile);
end

if ~isfile(adrenalFile)
    error('ไม่พบ Adrenal workbook: %s',adrenalFile);
end

outputFile = fullfile(baseDataDir,'CT_Master_QC.xlsx');

fprintf('\n============================================================\n');
fprintf(' STEP 4: MASTER QC\n');
fprintf('============================================================\n');
fprintf('Bone   : %s\n',boneFile);
fprintf('Aorta  : %s\n',aortaFile);
fprintf('Adrenal: %s\n',adrenalFile);
fprintf('Output : %s\n',outputFile);

%% 2. READ SOURCE TABLES
B = readtable(boneFile, ...
    'Sheet','02_BONE_L1_L4_AUTO', ...
    'VariableNamingRule','preserve');

A = readtable(aortaFile, ...
    'Sheet','03_Combined', ...
    'VariableNamingRule','preserve');

D = readtable(adrenalFile, ...
    'Sheet','Adrenal_Wide', ...
    'VariableNamingRule','preserve');

% Normalize linkage columns as string.
B.PatientID  = cleanString(B.PatientID);
A.PatientID  = cleanString(A.PatientID);
D.PatientID  = cleanString(D.PatientID);

B.SeriesName = cleanString(B.SeriesName);
A.SeriesName = cleanString(A.SeriesName);
D.SeriesName = cleanString(D.SeriesName);

B.HN = normalizeHN(B.HN);
A.HN = normalizeHN(A.HN);
D.HN = normalizeHN(D.HN);

fprintf('\nRows loaded:\n');
fprintf('  Bone   = %d\n',height(B));
fprintf('  Aorta  = %d\n',height(A));
fprintf('  Adrenal= %d\n',height(D));

%% 3. MASTER PATIENT LIST
allIDs = unique([B.PatientID; A.PatientID; D.PatientID]);
allIDs = allIDs(strlength(allIDs)>0);

% Natural numerical P001, P002, ...
patientNumber = nan(numel(allIDs),1);
for i = 1:numel(allIDs)
    tok = regexp(char(allIDs(i)),'^P(\d+)$','tokens','once');
    if ~isempty(tok)
        patientNumber(i) = str2double(tok{1});
    end
end

[~,ord] = sortrows([isnan(patientNumber), patientNumber],[1 2]);
allIDs = allIDs(ord);

%% 4. MASTER RESULT CONTAINERS
masterRows = {};
duplicateRows = {};

masterNames = { ...
    'HN','PatientID','CanonicalSeries', ...
    'Bone_Series','Aorta_Series','Adrenal_Series', ...
    'Duplicate_Series_Flag','HN_Mismatch_Flag','Data_Complete', ...
    ...
    'Bone_Valid_Levels','Bone_Review_Required', ...
    'Bone_L1_Status','Bone_L2_Status','Bone_L3_Status','Bone_L4_Status', ...
    'Bone_Mean_Valid_L1_L4_HU','Bone_Comments', ...
    ...
    'Aorta_Final_Status','Aorta_Review_Required', ...
    'Aorta_ActualSlabLength_mm','Aorta_CoverageFraction', ...
    'AAC_Present','AAC_Volume_mm3','AAC_AgatstonScore', ...
    'Aorta_Note', ...
    ...
    'Adrenal_Left_Status','Adrenal_Right_Status', ...
    'Adrenal_Review_Required', ...
    'Left_Adrenal_Volume_mL','Left_Adrenal_Mean_HU', ...
    'Right_Adrenal_Volume_mL','Right_Adrenal_Mean_HU', ...
    'Both_Adrenal_Volume_mL', ...
    ...
    'Overall_Status','Pipeline_Action','Overall_Reason'};

dupNames = {'PatientID','Source','HN','SeriesName','Selected','Reason'};

%% 5. ONE ROW PER PATIENT
for i = 1:numel(allIDs)

    pid = allIDs(i);

    idxB = find(B.PatientID == pid);
    idxA = find(A.PatientID == pid);
    idxD = find(D.PatientID == pid);

    % ------------------------------------------------------------
    % 5.1 Canonical series
    % Prefer the single Adrenal series because Adrenal_Wide normally
    % contains one selected processing series per patient.
    % ------------------------------------------------------------
    canonicalSeries = "";

    if numel(idxD) == 1
        canonicalSeries = D.SeriesName(idxD);
    elseif numel(idxB) == 1 && numel(idxA) == 1 && ...
            B.SeriesName(idxB) == A.SeriesName(idxA)
        canonicalSeries = B.SeriesName(idxB);
    end

    % Select one representative row from each source.
    selD = chooseRow(D,idxD,canonicalSeries);
    if strlength(canonicalSeries)==0 && ~isempty(selD)
        canonicalSeries = D.SeriesName(selD);
    end

    selB = chooseRow(B,idxB,canonicalSeries);
    selA = chooseRow(A,idxA,canonicalSeries);

    if strlength(canonicalSeries)==0
        if ~isempty(selB)
            canonicalSeries = B.SeriesName(selB);
        elseif ~isempty(selA)
            canonicalSeries = A.SeriesName(selA);
        end
    end

    % Re-run choice now that canonical series may have been established.
    selB = chooseRow(B,idxB,canonicalSeries);
    selA = chooseRow(A,idxA,canonicalSeries);
    selD = chooseRow(D,idxD,canonicalSeries);

    duplicateFlag = numel(idxB)>1 || numel(idxA)>1 || numel(idxD)>1;

    % ------------------------------------------------------------
    % 5.2 Duplicate-series audit table
    % ------------------------------------------------------------
    duplicateRows = appendDuplicateRows(duplicateRows,B,idxB,selB, ...
        pid,'BONE',canonicalSeries);
    duplicateRows = appendDuplicateRows(duplicateRows,A,idxA,selA, ...
        pid,'AORTA',canonicalSeries);
    duplicateRows = appendDuplicateRows(duplicateRows,D,idxD,selD, ...
        pid,'ADRENAL',canonicalSeries);

    % ------------------------------------------------------------
    % 5.3 HN reconciliation
    % ------------------------------------------------------------
    allHN = strings(0,1);
    if ~isempty(idxB), allHN = [allHN; B.HN(idxB)]; end %#ok<AGROW>
    if ~isempty(idxA), allHN = [allHN; A.HN(idxA)]; end %#ok<AGROW>
    if ~isempty(idxD), allHN = [allHN; D.HN(idxD)]; end %#ok<AGROW>

    allHN = unique(allHN(strlength(allHN)>0));
    hnMismatch = numel(allHN)>1;

    if isempty(allHN)
        HN = "";
    else
        HN = allHN(1);
    end

    % ------------------------------------------------------------
    % 5.4 Extract BONE values
    % ------------------------------------------------------------
    boneSeries = "";
    boneValidLevels = NaN;
    boneReview = "Missing";
    boneL1 = "MISSING";
    boneL2 = "MISSING";
    boneL3 = "MISSING";
    boneL4 = "MISSING";
    boneMeanHU = NaN;
    boneComments = "";

    if ~isempty(selB)
        boneSeries = B.SeriesName(selB);
        boneValidLevels = toDouble(B.Number_of_Level_Means(selB));
        boneReview = cleanScalarString(B.Review_Required(selB));
        boneL1 = cleanScalarString(B.L1_Auto_Status(selB));
        boneL2 = cleanScalarString(B.L2_Auto_Status(selB));
        boneL3 = cleanScalarString(B.L3_Auto_Status(selB));
        boneL4 = cleanScalarString(B.L4_Auto_Status(selB));
        boneMeanHU = toDouble(B.Mean_Valid_L1_L4_HU(selB));
        boneComments = cleanScalarString(B.Comments(selB));
    end

    % ------------------------------------------------------------
    % 5.5 Extract AORTA/AAC values
    % ------------------------------------------------------------
    aortaSeries = "";
    aortaStatus = "MISSING";
    aortaReview = "Missing";
    slabLength = NaN;
    coverageFraction = NaN;
    aacPresent = "Not assessed";
    aacVolume = NaN;
    aacAgatston = NaN;
    aortaNote = "";

    if ~isempty(selA)
        aortaSeries = A.SeriesName(selA);
        aortaStatus = cleanScalarString(A.Final_Status(selA));
        aortaReview = cleanScalarString(A.Review_Required(selA));
        slabLength = toDouble(A.ActualSlabLength_mm(selA));
        coverageFraction = toDouble(A.AortaCoverageFraction(selA));
        aacPresent = cleanScalarString(A.AAC_Present(selA));
        aacVolume = toDouble(A.AAC_Volume_mm3(selA));
        aacAgatston = toDouble(A.AAC_AgatstonScore(selA));
        aortaNote = cleanScalarString(A.Note(selA));
    end

    % ------------------------------------------------------------
    % 5.6 Extract ADRENAL values
    % ------------------------------------------------------------
    adrenalSeries = "";
    leftStatus = "MISSING";
    rightStatus = "MISSING";
    adrenalReview = "Missing";
    leftVol = NaN;
    leftHU = NaN;
    rightVol = NaN;
    rightHU = NaN;
    bothVol = NaN;

    if ~isempty(selD)
        adrenalSeries = D.SeriesName(selD);
        leftStatus = cleanScalarString(D.Left_Status(selD));
        rightStatus = cleanScalarString(D.Right_Status(selD));
        adrenalReview = cleanScalarString(D.Review_Required(selD));
        leftVol = toDouble(D.Left_Volume_mL(selD));
        leftHU = toDouble(D.Left_Mean_HU(selD));
        rightVol = toDouble(D.Right_Volume_mL(selD));
        rightHU = toDouble(D.Right_Mean_HU(selD));
        bothVol = toDouble(D.Both_Adrenal_Volume_mL(selD));
    end

    % ------------------------------------------------------------
    % 5.7 MASTER QC RULES
    % ------------------------------------------------------------
    reasons = strings(0,1);

    if duplicateFlag
        reasons(end+1,1) = "DUPLICATE_SERIES"; %#ok<SAGROW>
    end

    if hnMismatch
        reasons(end+1,1) = "HN_MISMATCH"; %#ok<SAGROW>
    end

    if isempty(selB)
        reasons(end+1,1) = "MISSING_BONE"; %#ok<SAGROW>
    elseif strcmpi(boneReview,"Yes") || ...
            (~isnan(boneValidLevels) && boneValidLevels < 4) || ...
            any(~strcmpi([boneL1 boneL2 boneL3 boneL4],"OK"))
        reasons(end+1,1) = "BONE_REVIEW"; %#ok<SAGROW>
    end

    if isempty(selA)
        reasons(end+1,1) = "MISSING_AORTA"; %#ok<SAGROW>
    elseif strcmpi(aortaStatus,"QC_REVIEW") || strcmpi(aortaReview,"Yes")
        reasons(end+1,1) = "AORTA_QC_REVIEW"; %#ok<SAGROW>
    elseif ~strcmpi(aortaStatus,"OK") && ~strcmpi(aortaStatus,"EXCLUDE")
        reasons(end+1,1) = "AORTA_" + upper(aortaStatus); %#ok<SAGROW>
    end

    if isempty(selD)
        reasons(end+1,1) = "MISSING_ADRENAL"; %#ok<SAGROW>
    elseif strcmpi(adrenalReview,"Yes") || ...
            ~strcmpi(leftStatus,"OK") || ~strcmpi(rightStatus,"OK")
        reasons(end+1,1) = "ADRENAL_REVIEW"; %#ok<SAGROW>
    end

    dataComplete = ~isempty(selB) && ~isempty(selA) && ~isempty(selD);

    % Explicit protocol exclusion has highest precedence.
    if ~isempty(selA) && strcmpi(aortaStatus,"EXCLUDE")
        overallStatus = "EXCLUDE";
        pipelineAction = "EXCLUDE_BY_PROTOCOL";
        reasons = ["AORTA_EXCLUDE"; reasons(:)];

    elseif isempty(reasons)
        overallStatus = "PASS";
        pipelineAction = "READY_FOR_ANALYSIS";
        reasons = "ALL_AUTOMATED_QC_PASSED";

    else
        overallStatus = "REVIEW";
        pipelineAction = "MANUAL_QC_REQUIRED";
    end

    reasons = unique(reasons,'stable');
    overallReason = strjoin(reasons,"; ");

    % ------------------------------------------------------------
    % 5.8 Save master row
    % ------------------------------------------------------------
    masterRows(end+1,:) = { ... %#ok<SAGROW>
        char(HN),char(pid),char(canonicalSeries), ...
        char(boneSeries),char(aortaSeries),char(adrenalSeries), ...
        yesNo(duplicateFlag),yesNo(hnMismatch),yesNo(dataComplete), ...
        ...
        boneValidLevels,char(boneReview), ...
        char(boneL1),char(boneL2),char(boneL3),char(boneL4), ...
        boneMeanHU,char(boneComments), ...
        ...
        char(aortaStatus),char(aortaReview), ...
        slabLength,coverageFraction, ...
        char(aacPresent),aacVolume,aacAgatston,char(aortaNote), ...
        ...
        char(leftStatus),char(rightStatus),char(adrenalReview), ...
        leftVol,leftHU,rightVol,rightHU,bothVol, ...
        ...
        char(overallStatus),char(pipelineAction),char(overallReason)};
end

Master = cell2table(masterRows,'VariableNames',masterNames);

if isempty(duplicateRows)
    DuplicateSeries = cell2table(cell(0,numel(dupNames)), ...
        'VariableNames',dupNames);
else
    DuplicateSeries = cell2table(duplicateRows,'VariableNames',dupNames);
end

%% 6. QC SUMMARY
nTotal = height(Master);
nPass = nnz(strcmpi(Master.Overall_Status,'PASS'));
nReview = nnz(strcmpi(Master.Overall_Status,'REVIEW'));
nExclude = nnz(strcmpi(Master.Overall_Status,'EXCLUDE'));

summaryMetric = { ...
    'Unique patients'; ...
    'PASS'; ...
    'REVIEW'; ...
    'EXCLUDE'; ...
    'Complete Bone+Aorta+Adrenal'; ...
    'Duplicate-series patients'; ...
    'HN mismatch patients'; ...
    'Bone review patients'; ...
    'Aorta QC-review patients'; ...
    'Adrenal review patients'; ...
    'AAC present among selected rows'};

summaryCount = [ ...
    nTotal; ...
    nPass; ...
    nReview; ...
    nExclude; ...
    nnz(strcmpi(Master.Data_Complete,'Yes')); ...
    nnz(strcmpi(Master.Duplicate_Series_Flag,'Yes')); ...
    nnz(strcmpi(Master.HN_Mismatch_Flag,'Yes')); ...
    nnz(contains(Master.Overall_Reason,'BONE_REVIEW')); ...
    nnz(contains(Master.Overall_Reason,'AORTA_QC_REVIEW')); ...
    nnz(contains(Master.Overall_Reason,'ADRENAL_REVIEW')); ...
    nnz(strcmpi(Master.AAC_Present,'Yes'))];

summaryPercent = 100*summaryCount/max(nTotal,1);

QCSummary = table(summaryMetric,summaryCount,summaryPercent, ...
    'VariableNames',{'Metric','Count','Percent_of_Unique_Patients'});

%% 7. REASON COUNTS
reasonTokens = strings(0,1);

for i = 1:height(Master)
    these = split(string(Master.Overall_Reason(i)),';');
    these = strtrim(these);
    these = these(strlength(these)>0);
    reasonTokens = [reasonTokens; these(:)]; %#ok<AGROW>
end

uReasons = unique(reasonTokens,'stable');
reasonCount = zeros(numel(uReasons),1);

for i = 1:numel(uReasons)
    reasonCount(i) = nnz(reasonTokens == uReasons(i));
end

[reasonCount,ix] = sort(reasonCount,'descend');
uReasons = uReasons(ix);

ReasonCounts = table(cellstr(uReasons),reasonCount, ...
    'VariableNames',{'Reason','Patient_Count'});

%% 8. PARAMETERS / DECISION RULES
parameter = { ...
    'Master QC unit'; ...
    'PASS definition'; ...
    'REVIEW definition'; ...
    'EXCLUDE definition'; ...
    'EXCLUDE precedence'; ...
    'Duplicate series rule'; ...
    'Canonical series rule'; ...
    'Missing component rule'; ...
    'Bone QC rule'; ...
    'Aorta QC rule'; ...
    'Adrenal QC rule'; ...
    'Clinical interpretation'; ...
    'Bone source file'; ...
    'Aorta source file'; ...
    'Adrenal source file'};

value = { ...
    'One row per unique PatientID'; ...
    'Bone + Aorta + Adrenal present; component automated QC clean; no duplicate/HN mismatch'; ...
    'Manual QC required for missing result, duplicate series, HN mismatch, component QC flag or segmentation issue'; ...
    'Explicit Final_Status=EXCLUDE from selected Aorta 8-cm result'; ...
    'Aorta protocol EXCLUDE overrides PASS/REVIEW; other reasons are retained in Overall_Reason'; ...
    'Duplicate source rows are logged and trigger REVIEW unless already protocol EXCLUDE'; ...
    'Prefer single Adrenal series; exact series match across sources; otherwise Standard before ThinSlice'; ...
    'Missing Bone/Aorta/Adrenal -> REVIEW, not automatic EXCLUDE'; ...
    'Review if Review_Required=Yes, valid levels <4, or any selected L1-L4 Auto_Status is not OK'; ...
    'QC_REVIEW/Review_Required=Yes -> REVIEW; explicit EXCLUDE -> EXCLUDE'; ...
    'Review if Review_Required=Yes or left/right selected status is not OK'; ...
    'No clinical abnormality/diagnosis is assigned by this script'; ...
    boneFile; ...
    aortaFile; ...
    adrenalFile};

Parameters = table(parameter,value,'VariableNames',{'Parameter','Value'});

%% 9. WRITE OUTPUT
if isfile(outputFile)
    delete(outputFile);
end

writetable(Master,outputFile,'Sheet','Master_QC');
writetable(QCSummary,outputFile,'Sheet','QC_Summary');
writetable(ReasonCounts,outputFile,'Sheet','Reason_Counts');
writetable(DuplicateSeries,outputFile,'Sheet','Duplicate_Series');
writetable(Parameters,outputFile,'Sheet','Parameters');

fprintf('\n============================================================\n');
fprintf(' STEP 4 COMPLETE\n');
fprintf('============================================================\n');
fprintf('Unique patients : %d\n',nTotal);
fprintf('PASS            : %d\n',nPass);
fprintf('REVIEW          : %d\n',nReview);
fprintf('EXCLUDE         : %d\n',nExclude);
fprintf('Output          : %s\n',outputFile);
fprintf('\n');

%% ========================================================================
% LOCAL FUNCTIONS
% ========================================================================

function filePath = findLatestFile(folder,pattern)

d = dir(fullfile(folder,pattern));
d = d(~[d.isdir]);

if isempty(d)
    error('ไม่พบไฟล์ pattern: %s',fullfile(folder,pattern));
end

[~,idx] = max([d.datenum]);
filePath = fullfile(d(idx).folder,d(idx).name);
end

function s = cleanString(x)

if isstring(x)
    s = strtrim(x);
elseif iscell(x)
    s = strings(size(x));
    for i = 1:numel(x)
        if isempty(x{i}) || (isnumeric(x{i}) && all(isnan(x{i})))
            s(i) = "";
        else
            s(i) = strtrim(string(x{i}));
        end
    end
elseif iscategorical(x)
    s = strtrim(string(x));
else
    s = strtrim(string(x));
end

s(ismissing(s)) = "";
end

function h = normalizeHN(x)

s = cleanString(x);
h = strings(size(s));

for i = 1:numel(s)
    t = strtrim(s(i));

    if strlength(t)==0
        h(i) = "";
        continue;
    end

    % Excel may render a numeric HN as "463030" instead of "0463030".
    if ~isempty(regexp(char(t),'^\d+$','once')) && strlength(t)<7
        n = str2double(t);
        h(i) = string(sprintf('%07d',round(n)));
    else
        h(i) = t;
    end
end
end

function idx = chooseRow(T,indices,canonicalSeries)

idx = [];

if isempty(indices)
    return;
end

if numel(indices)==1
    idx = indices(1);
    return;
end

% Exact canonical-series match.
if strlength(canonicalSeries)>0
    m = indices(T.SeriesName(indices)==canonicalSeries);
    if numel(m)==1
        idx = m(1);
        return;
    elseif numel(m)>1
        indices = m;
    end
end

% Prefer Standard over ThinSlice for the primary working series.
isStandard = contains(T.SeriesName(indices),'Standard','IgnoreCase',true);
standardIdx = indices(isStandard);

if numel(standardIdx)==1
    idx = standardIdx(1);
    return;
elseif numel(standardIdx)>1
    indices = standardIdx;
end

% Stable fallback: first row. Duplicate status remains flagged separately.
idx = indices(1);
end

function rows = appendDuplicateRows(rows,T,indices,selectedIdx,pid,sourceName,canonicalSeries)

if numel(indices)<=1
    return;
end

for k = 1:numel(indices)
    ii = indices(k);

    if ii == selectedIdx
        selectedText = 'Yes';
    else
        selectedText = 'No';
    end

    if T.SeriesName(ii)==canonicalSeries
        why = 'Exact canonical-series match';
    elseif contains(T.SeriesName(ii),'Standard','IgnoreCase',true)
        why = 'Standard candidate';
    elseif contains(T.SeriesName(ii),'ThinSlice','IgnoreCase',true)
        why = 'ThinSlice candidate';
    else
        why = 'Additional candidate';
    end

    rows(end+1,:) = { ... %#ok<AGROW>
        char(pid),sourceName,char(T.HN(ii)),char(T.SeriesName(ii)), ...
        selectedText,why};
end
end

function x = toDouble(v)

if isnumeric(v)
    x = double(v(1));
elseif iscell(v)
    if isempty(v) || isempty(v{1})
        x = NaN;
    elseif isnumeric(v{1})
        x = double(v{1});
    else
        x = str2double(string(v{1}));
    end
else
    x = str2double(string(v(1)));
end

if isempty(x) || ~isfinite(x)
    x = NaN;
end
end

function s = cleanScalarString(v)

s = cleanString(v);

if isempty(s)
    s = "";
else
    s = s(1);
end
end

function s = yesNo(tf)
if tf
    s = 'Yes';
else
    s = 'No';
end
end
