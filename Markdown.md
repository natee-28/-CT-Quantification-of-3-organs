# Automated Medical Image Analysis Pipeline (3-in-1 Master Edition)

An automated, memory-optimized 3-in-1 medical image processing pipeline built in MATLAB. This pipeline seamlessly integrates deep learning-based multi-organ segmentations to perform robust vertebral body trabecular quantification, abdominal aortic calcification (AAC) scoring, and whole-adrenal-gland volumetric analysis from non-contrast CT scans.

Optimized specifically for constrained hardware environments (e.g., 16 GB System RAM / Windows OS), this framework circumvents typical `ArrayMemoryError` issues through dynamic array management and controlled parallel execution structures.

---

## 🌟 Key Features & Architecture

### 1. Vertebral Body Trabecular Quantification (C4 Specifications)
* **Direct Integration:** Automates direct volumetric intersections between standard anatomical segmentations and target bone labels inside virtual memory, bypassing heavy disk write/read loops.
* **Smart Slice Selection:** Geometrically locates the precise mid-vertebral-body slice (L1–L4) using 3-D centroid distribution and performs isolated 2-D connectivity filtering (`bwconncomp`).
* **Automated Visual QC:** Generates high-resolution overlay contours (`.png`) inside an invisible figure buffer to prevent clinical monitor workspace interruption.

### 2. Aorta 8-cm Slab Cutting & AAC Scoring (2-in-1 Module)
* **Anatomical Mapping:** Identifies the mid-L1 axial landmark and tracks inferior trajectory using lower lumbar positions (L2/L3/L4) to segment an exact 80-mm aortic cylinder block.
* **Agatston Scoring Integration:** Quantifies calcified lesions slice-by-slice using a dual-gate criterion (≥ 130 HU density and ≥ 1.0 mm² area filtering).
* **4-Category Density Weighting:** Automatically classifies and assigns weighted index factors based on maximum spatial attenuation profiles:
  * **Category 1 (130–199 HU):** Factor × 1
  * **Category 2 (200–299 HU):** Factor × 2
  * **Category 3 (300–399 HU):** Factor × 3
  * **Category 4 (≥ 400 HU):** Factor × 4
* **3-D Morphological Analytics (`AAC_3D_PlaqueCount`):** Utilizes a full 26-connectivity topological scan to count distinct, interconnected calcification masses throughout the 3-D volume, offering far greater anatomical precision than traditional 2-D sequential counting.

### 3. Whole-Adrenal-Gland Analytics
* **Bilateral Segmentation Tracking:** Isolates left and right adrenal gland structures separately to compute absolute volumetric spacing (mL).
* **Attenuation Profiling:** Extracts multi-parameter statistical metadata (Mean, SD, Median, Min, Max HU values) on raw unenhanced scans.
* **Spatial Quality Control:** Incorporates automated boundary-touching detection algorithms to alert researchers if an organ gets clipped by scan range limitations.

### 4. Enterprise-Grade Hospital Mapping
* **Automated HN Lookup:** Features an underlying data-dictionary parser that automatically links internal research codes (`P00x`) to official Hospital Numbers (`HN`) mapped from source spreadsheets, maintaining leading zeros (`%07d`) and trailing text syntax.

---

## 🛠️ Environment Deployment & Windows Patching

To circumvent deployment constraints on edge devices with 16 GB RAM where standard packaging is unsupported, follow this manual deployment workflow:

### 1. Conda Environment Registration
Open **Anaconda Prompt** as **Administrator** and register dependencies:
```cmd
conda create -n ts_env python=3.10 -y
conda activate ts_env
pip install psutil gputil
```

### 2. Manual Module Extraction & Windows OS Patching
1. Download the source engine repository and extract it directly into:  
   `C:\Users\user\Downloads\Skellytour-main\`
2. **Critical OS Bug Patch:** Open `skellytour/mainmethod.py` in a text editor. Search for the Unix-specific host command `os.uname()` and modify it to prevent runtime failure on Windows systems:
   * **Original Unix string:** `os.uname()`
   * **Windows deployment patch:** Replace with `os.name` (or a static identifier string like `'windows'`).

### 3. Host System Memory Allocation
For seamless 3-D resampling arrays without memory chokeouts, increase the system's virtual swap file memory:
* Go to **Advanced System Settings** → **Performance Settings** → **Advanced Virtual Memory**.
* Set dry-run paging partition values on the primary solid-state drive (SSD):
  * **Initial Size:** `32000 MB`
  * **Maximum Size:** `64000 MB`

---

## 💻 MATLAB Runtime Command Structure

Configure your path scripts within the primary loop block. The engine automatically initiates an asynchronous popup shell command (`start /wait`), forcing Windows to process instances step-by-step while piping continuous performance metric data logs right back to the researcher:

```matlab
% Set temporary localized path environment block to fetch adjacent sub-modules
cmd = sprintf(['start "AI_Runner" /wait cmd /c "' ...
               'call "%s" activate ts_env && ' ...
               'set PYTHONPATH=%s&& ' ...
               'python "%s" -i "%s" -o "%s" -m medium -d gpu -g 0 --fast --subseg"'], ...
               anacondaBatPath, skellyBaseDir, skellyScriptPath, ctFile, skellyOutDir);
```

### Dynamic Resource Cleanup
To preserve stability during continuous iteration, multi-dimensional structures are completely purged from cache addresses after every execution sequence:
```matlab
if p > 1
    clear CT aortaMask l1Mask aorta8 rawCalcium calciumMask skellyMask;
end
pause(0.5); % Forces Windows kernel memory release loop
```

---

## 📊 Standardized Reporting & Output Format

All calculated metrics pass through unified table structures to construct detailed multi-tab worksheets:
* `02_BONE_L1_L4_AUTO`: Wide clinical template containing linked patient identifiers, L1–L4 mean HU records, index values, and validation flags.
* `Aorta_8cm_AAC_Summary`: Unified records tracking target aorta cylinder properties and sequential Agatston categorical distributions side-by-side.
* `Measurement_Long` / `Run_Log`: Detailed transaction log history providing auditing trails for clinical diagnostics.

---

## ⚠️ Scientific Disclaimer & Limitations
This pipeline is designed exclusively for large-cohort quantitative clinical research and structured bulk data screening. It performs organ-wide and region-wide volumetric assessment. This software does **NOT** isolate local lesions, define structural abnormalities, or produce automated clinical diagnoses. All final numerical classifications must be audited and signed off by a qualified Radiologist or Medical Imaging Expert.
