import os
import subprocess

# 1. ระบุโฟลเดอร์ภาพที่รันผ่านมาจาก MATLAB เรียบร้อยแล้ว
input_dir = r"F:\knomjeen_\File_non_contrast_nii"

# 2. รายชื่อ ROI ที่ต้องการเจาะจงเซกเมนต์ตามที่แจ้ง (ช่วยเซฟแรมการ์ดจอ 6GB ในโหมดความละเอียดปกติ)
roi_list = [
    "adrenal_gland_left",
    "adrenal_gland_right",
    "aorta",
    "vertebrae_L1",
    "vertebrae_L2",
    "vertebrae_L3",
    "vertebrae_L4"
]
roi_subset_str = " ".join(roi_list)

# 3. แสกนหาไฟล์ .nii ทั้งหมดในโฟลเดอร์ และเรียงลำดับ P001, P002...
all_files = [f for f in os.listdir(input_dir) if f.endswith('.nii') and not f.startswith('.')]
all_files.sort()

# ล็อกเป้าหมายรันเฉพาะ 20 เคสแรกเพื่อความปลอดภัยต่อเครื่องพกพาตัวเล็ก
target_files = all_files[:20]

print(f"=== เริ่มต้นการรันระบบ Batch Automation (ขีดจำกัดสูงสุด {len(target_files)} เคส) ===")

for idx, file_name in enumerate(target_files, 1):
    input_path = os.path.join(input_dir, file_name)
    
    # แกะชื่อเอาต์พุต เช่น ตัดส่วนนามสกุลออกเหลือ P001_xxx_output_highres
    case_name = os.path.splitext(file_name)[0]
    output_folder = os.path.join(input_dir, f"{case_name}_output_highres")
    
    print(f"\n[{idx}/{len(target_files)}] กำลังรันโหมดละเอียดปกติเคส: {file_name}")
    
    # คำสั่งรันละเอียดปกติ (ไม่พ่วง --fast) เจาะจงใช้การ์ดจอ NVIDIA (Device 0) และจำกัด ROI
    cmd = f"set CUDA_VISIBLE_DEVICES=0 && TotalSegmentator -i \"{input_path}\" -o \"{output_folder}\" --roi_subset {roi_subset_str}"
    
    # ส่งคำสั่งไปประมวลผลที่ระบบ Command Line
    subprocess.run(cmd, shell=True)

print("\n=========================================================")
print("  ประมวลผลระบบอัตโนมัติครบ 20 เคสแรกเสร็จสิ้นเรียบร้อยแล้วครับ!  ")
print("=========================================================")
