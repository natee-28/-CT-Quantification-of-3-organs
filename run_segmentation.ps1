# ========================================================================
# PowerShell Automation: Data Arranger & TotalSegmentator Batch Runner
# ========================================================================
clear-host
Write-Host "🚀 เริ่มระบบจัดระเบียบคลังข้อมูลและประมวลผล Multi-Organ Masks..." -ForegroundColor Cyan

# วนลูปค้นหาไฟล์ภาพดิบ Non-Contrast ที่เราเลือกไว้ในโฟลเดอร์ปัจจุบัน
Get-ChildItem -Filter "*_NonContrast_*.nii.gz" | ForEach-Object {
    
    $inputFile = $_.FullName
    $baseName = $_.BaseName.Replace(".nii", "")
    
    # 1. จัดเรียงโครงสร้างข้อมูล: สร้างโฟลเดอร์ปลายทางแยกรายคนเพื่อเก็บผลลัพธ์
    $outputCaseFolder = Join-Path $_.DirectoryName ($baseName + "_Masks")
    if (-not (Test-Path $outputCaseFolder)) {
        New-Item -ItemType Directory -Path $outputCaseFolder | Out-Null
    }
    
    # 2. ตั้งชื่อตรวจสอบไฟล์ผลลัพธ์หลักปลายทาง (เช็กเผื่อรันซ้ำ)
    $checkFile = Join-Path $outputCaseFolder "aorta.nii.gz"
    
    if (Test-Path $checkFile) {
        Write-Host "  [Skip] เคส $($baseName) มีข้อมูล Mask เดิมอยู่แล้ว (ข้ามการรันซ้ำ)" -ForegroundColor Yellow
    } else {
        Write-Host "  [Running] กำลังส่งคิวประมวลผล -> $($baseName)" -ForegroundColor Green
        
        # 3. ยิงคำสั่งตรงเข้าตัว Command-line ของ TotalSegmentator เจาะจง 3 อวัยวะ
        # ระบบจะพ่นไฟล์ aorta.nii.gz, adrenal_gland_right.nii.gz, adrenal_gland_left.nii.gz ออกมาโดยอัตโนมัติ
        TotalSegmentator -i $inputFile -o $outputCaseFolder --ta_filter aorta adrenal_gland_right adrenal_gland_left
    }
}

Write-Host "`n🎉 PowerShell จัดการจัดเรียงคิวและรันชุดข้อมูลเสร็จสิ้นเรียบร้อย!" -ForegroundColor Cyan
