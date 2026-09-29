# Adrenal Hypercortisolism CT Quantification Pipeline

เวอร์ชันนี้เป็น **working research pipeline** สำหรับประมวลผล non-contrast CT แบบอัตโนมัติ/กึ่งอัตโนมัติ โดยใช้ MATLAB + TotalSegmentator + Skellytour และส่งออกผล quantitative ลง Excel

> จุดประสงค์ของ `Main.m` คือเป็น **launcher + project map** ไม่ใช่ให้รันทุกขั้นต่อกันแบบ blind automation  
> แต่ละขั้นควรผ่าน QC ก่อนเข้าสู่ขั้นถัดไป โดยเฉพาะ cohort ขนาดใหญ่

---

## 1. Pipeline overview

```text
Original DICOM
    |
    v
Step 1 — step1_master_C5.m
    |
    +--> select axial non-contrast series
    +--> per-slice HU conversion
    +--> NIfTI with physical spacing + sform
    +--> DICOM master log
    |
    v
TotalSegmentator — batch_run_20.py
    |
    +--> adrenal_gland_left/right
    +--> aorta
    +--> vertebrae_L1-L4
    |
    +------------------------------+
    |                              |
    v                              v
Step 2                         Adrenal
step2_Skel_TS.m                calc_adrenal_TS.m
    |                              |
    +--> Skellytour FULL            +--> left/right gland volume
    +--> trabecular label 1         +--> mean/SD HU
    +--> TS L1-L4                   +--> max axial area
    +--> body-trabecular ROI        +--> Excel
    +--> mid-body HU/area
    +--> Excel
    |
    v
Step 3 — Step3_Aorta_8cm_midL1.m
    |
    +--> mid-L1 anatomical reference
    +--> 80-mm inferior aorta segment
    +--> save aorta 8-cm NIfTI
    +--> detect calcium >=130 HU
    +--> AAC area / volume / Agatston / HU
    +--> save AAC NIfTI + Excel
```

---

## 2. Main project files

| File | Purpose |
|---|---|
| `Main.m` | Launcher / project menu |
| `step1_master_C5.m` | DICOM selection, HU conversion, NIfTI export |
| `batch_run_20.py` | TotalSegmentator batch processing |
| `step2_Skel_TS.m` | Skellytour + TotalSegmentator L1–L4 trabecular pipeline |
| `Step3_Aorta_8cm_midL1.m` | Aorta 8 cm + AAC quantification |
| `calc_adrenal_TS.m` | Left/right whole-adrenal quantitative analysis |
| `Ref_list_30AUG.xlsx` | P00x ↔ HN mapping; worksheet `Code` |

Historical development files such as `C1`, `C2`, `C3`, `C4` are useful for audit/debugging but are **not the current primary workflow**.

---

## 3. How to run

In MATLAB:

```matlab
Main
```

Select only **one major step per launch**.

Recommended sequence:

1. `Step 1`
2. Review `DICOM_Master_Log_Batch_C5.xlsx`
3. Run `TotalSegmentator`
4. Review failures / unusual series / coverage
5. Run `Step 2`
6. Run `Step 3`
7. Run `Adrenal`
8. Merge or transfer final quantitative outputs into the clinical/research template after QC

---

# STEP 1 — DICOM → NIfTI

## Script

`step1_master_C5.m`

## Current role

- Finds DICOM files recursively.
- Groups images by `SeriesInstanceUID`.
- Selects axial non-contrast candidates.
- Rejects known contrast/protocol/reconstruction keywords.
- Converts stored DICOM pixel values to HU using per-slice rescale information.
- Writes NIfTI.
- Preserves physical spacing and NIfTI spatial geometry (`sform=1`).
- Produces a DICOM master log.

## Why C5?

C5 includes the important fixes from C4 plus improved series selection.

Examples from pilot testing:

- P004: `plain` selected; `D-KUB` rejected.
- P005: explicit `noncontrast` selected correctly even though the word contains `contrast`.

## Important limitation

Series classification still depends partly on `SeriesDescription`.  
Unusual CTA/contrast series or vendor-specific descriptions should be **flagged and reviewed**, not fixed by adding keywords blindly during a long batch.

---

# TotalSegmentator

## Script

`batch_run_20.py`

The filename is historical; check the actual line:

```python
target_files = ...
```

before every large run.

Python indexing reminder:

```python
all_files[:20]   # files 1–20
all_files[20:]   # starts from file 21
```

## Current target structures

```text
adrenal_gland_left
adrenal_gland_right
aorta
vertebrae_L1
vertebrae_L2
vertebrae_L3
vertebrae_L4
```

## Input expectation

The input NIfTI should remain in CT HU.

Do **not** perform case-wise min-max normalization or z-score normalization before TotalSegmentator.

## Failure handling

Possible failures should be logged, for example:

```text
GPU_OOM
POSSIBLE_WRONG_SERIES
EMPTY_SEGMENTATION
GEOMETRY_PROBLEM
```

A TotalSegmentator failure is not automatically evidence of clinical abnormality.

---

# STEP 2 — Vertebral trabecular analysis

## Script

`step2_Skel_TS.m`

## Skellytour settings

Current working settings:

```text
Model     : medium
Device    : GPU 0
Mode      : FULL prediction
--fast    : NOT used
--subseg  : enabled
Trabecular label : 1
```

Pilot timing on RTX 4080 was approximately ~2 minutes/case for the full Skellytour workflow, depending on scan volume.

## Workflow

```text
Original CT
    +
Skellytour label 1
    +
TS vertebrae_L1-L4
    |
    v
TS x Skelly trabecular intersection
    |
    v
Axial body isolation
    |
    v
P00x_L1_body_trabecular.nii.gz
...
P00x_L4_body_trabecular.nii.gz
    |
    v
mid-vertebral-body axial slice
    |
    v
Area + Mean HU + SD HU
```

## Current body-isolation parameters

```text
BodyOpeningRadius_mm = 3.0 mm
BodyPresenceFraction = 0.20
MinimumSlicePixels   = 20
```

These are **algorithmic working parameters**, not clinical diagnostic thresholds.

The opening is expressed in physical mm so that varying in-plane pixel spacing does not directly change the intended physical scale.

## Measurement count

Current setting:

```matlab
nMeasurements = 1;
```

This measures the central/mid-body slice only.

If the clinical team later confirms three adjacent measurements:

```matlab
nMeasurements = 3;
```

with the current order:

```text
M1 = center
M2 = center - 1 slice
M3 = center + 1 slice
```

Do not describe the automated repeated values as manual intraobserver repeatability unless the study protocol explicitly defines it that way.

## Clinical abnormalities

The automated pipeline intentionally does **not** decide:

- fracture/compression
- hemangioma
- focal sclerosis
- bone island
- Schmorl node
- hardware
- significant artifact
- other clinical vertebral abnormalities

These remain clinical-review variables.

---

# STEP 3 — Aorta 8 cm from mid-L1 + AAC

## Script

`Step3_Aorta_8cm_midL1.m`

## Core parameters

### Start reference

```text
MID_L1
```

The midpoint of the TotalSegmentator L1 mask in the superior–inferior direction is used as the current working anatomical start point.

This is a **working protocol definition**.  
If the research team later specifies superior endplate, inferior endplate, or another landmark, the reference should be changed explicitly.

### Target length

```text
80 mm
```

The pipeline analyzes an aortic segment approximately 8 cm inferior from mid-L1.

Number of slices:

```text
round(80 / slice_spacing)
```

Examples:

```text
dz = 1.0 mm  -> 80 slices
dz = 2.5 mm  -> 32 slices
dz = 3.0 mm  -> 27 slices (~81 mm)
```

### Inferior direction

The code does not assume that increasing NIfTI slice index always means inferior.

Direction is inferred from:

```text
L4 -> if unavailable L3 -> if unavailable L2
```

relative to L1.

### Aorta source

```text
TotalSegmentator aorta.nii.gz
```

### Coverage rule

If the CT volume does not extend far enough to provide the requested 80-mm segment:

```text
Status = EXCLUDE
Note   = INSUFFICIENT_8CM_COVERAGE
```

If the volume covers 8 cm but the aorta mask has substantial gaps:

```text
Status = QC_REVIEW
```

Current QC threshold:

```text
Minimum_Aorta_Coverage_Fraction = 0.90
```

---

## AAC parameters

### Calcium threshold

```text
>=130 HU
```

within the defined aorta-analysis mask.

### Minimum 2-D lesion area

```text
1.0 mm²
```

Small isolated candidates below this area are excluded from AAC scoring in the current working method.

### Aorta dilation

Current:

```text
0 mm
```

The first-pass method uses the strict TotalSegmentator aorta boundary.

Reason:

- avoids pulling adjacent bone/high-density structures into the analysis,
- but may clip wall calcification if the segmentation boundary does not include the full plaque.

Representative overlay QC should be completed before any decision to introduce 1–2 mm mask dilation.

### Agatston density factors

Peak lesion HU per axial slice:

```text
130–199 HU -> factor 1
200–299 HU -> factor 2
300–399 HU -> factor 3
>=400 HU   -> factor 4
```

For each 2-D calcified lesion:

```text
Agatston contribution = lesion area (mm²) × density factor
```

The contributions are summed across the analyzed 8-cm aortic segment.

### Connectivity

```text
2-D lesion grouping : 8-connectivity
3-D plaque objects  : 26-connectivity
```

### No detected calcium

If no candidate meeting the working criteria is found:

```text
AAC_Present       = No
AAC_TotalArea_mm2 = 0
AAC_Volume_mm3    = 0
AAC_AgatstonScore = 0
```

This is a measured negative result, not missing data.

---

# Adrenal quantification

## Script

`calc_adrenal_TS.m`

## Source

```text
TotalSegmentator adrenal_gland_left.nii.gz
TotalSegmentator adrenal_gland_right.nii.gz
```

Left and right are quantified separately.

## Current outputs

- voxel count
- volume (mm³ / mL)
- mean HU
- SD HU
- median HU
- min/max HU
- maximum axial cross-sectional area
- slice of maximum area
- basic coverage QC

## Critical interpretation note

This script measures the **whole adrenal gland mask from TotalSegmentator**.

It is **not automatically equivalent to an adrenal-lesion segmentation**.

Do not label these outputs as lesion volume or lesion attenuation unless the segmentation is specifically validated/defined for the lesion.

Clinical morphology and abnormality interpretation are outside this automated script.

---

# HN / Study linkage

Processing files use IDs such as:

```text
P001
P002
...
P303
```

The research linkage identifier is HN.

Mapping source:

```text
F:\knomjeen_\Ref_list_30AUG.xlsx
Worksheet: Code
```

Keep both variables:

```text
PatientID = P00x     # processing / de-identified pipeline ID
HN                    # research linkage ID
```

Do not rename NIfTI files to HN unless there is a specific data-governance reason to do so.

---

# Coverage / exclusion philosophy

A simple coverage rule is preferred over forcing incomplete quantitative analysis.

For the combined study, an ideal analyzable case should have adequate coverage for:

```text
Adrenal glands
L1-L4 vertebral analysis
80-mm aortic segment inferior from mid-L1
```

Possible notes:

```text
Limited CT coverage
Incomplete adrenal coverage
Incomplete L1-L4 coverage
Insufficient inferior coverage for 80-mm aortic analysis
```

Clinical abnormalities are not automatically classified by this pipeline.

---

# Suggested QC statuses

Use explicit flags rather than silently forcing a numeric result:

```text
OK
QC_REVIEW
EXCLUDE
FAILED
MISSING_MASK
EMPTY_MASK
GEOMETRY_MISMATCH
GPU_OOM
POSSIBLE_WRONG_SERIES
INSUFFICIENT_8CM_COVERAGE
NO_AAC_DETECTED
AAC_DETECTED
```

---

# Operational notes

- TotalSegmentator and Skellytour use the `ts_env` conda environment.
- Skellytour is configured for RTX GPU inference.
- Avoid running 3D Slicer or other heavy 3-D applications during long Skellytour runs on machines with limited system RAM.
- Save intermediate NIfTI masks. They are useful for QC, reproducibility, and later method validation.
- Do not modify thresholds during a long cohort run unless the reason is documented and the earlier cases are rerun consistently.

---

# Current project status

Working major components:

- [x] DICOM selection and HU-preserving NIfTI export
- [x] NIfTI physical spacing / sform correction
- [x] TotalSegmentator L/R adrenal, aorta, L1-L4
- [x] Skellytour GPU full subsegmentation
- [x] body-trabecular L1-L4 mask generation
- [x] vertebral mid-body Area / Mean HU / SD HU
- [x] HN mapping
- [x] 80-mm aorta extraction from mid-L1
- [x] AAC >=130 HU detection and quantification
- [x] whole-adrenal left/right quantitative extraction
- [ ] final clinical definition of HU measurements 1/2/3
- [ ] clinical abnormality review
- [ ] representative validation of aortic wall calcium coverage
- [ ] final cohort-level QC / exclusions
- [ ] final merge into study workbook

---

## Practical rule

**Automation measures. QC flags. Clinical interpretation stays with the clinical team.**
