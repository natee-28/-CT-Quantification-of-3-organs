clear; clc;

%% 1. กำหนดโฟลเดอร์และชื่อไฟล์ (Input / Output Paths)
% *รวนปรับแก้ Path เหล่านี้ให้ตรงกับตำแหน่งไฟล์จริงในเครื่องของคุณ*
anacondaBatPath = 'C:\Users\YOUR_USERNAME\anaconda3\condabin\conda.bat'; % Path ไปยังตัวควบคุม conda ของระบบ
inputNifti     = 'F:\knomjeen_\File_non_contrast_nii\P001_Ser5_NonContrast_ThinSlice.nii.gz';
outputFolder   = 'F:\knomjeen_\File_non_contrast_nii\P001_Output_Masks';

%% 2. มัดรวมคำสั่งเปิด Env + รันโมเดล (วิธีที่ 1)
% รูปแบบ: เรียกใช้ conda.bat -> สั่ง activate env -> สั่งรัน TotalSegmentator ต่อทันที
% (หากเปลี่ยนเป็น Skellytour ในอนาคต ให้แก้ข้อความคำสั่งหลัง && ได้เลยครับ)

cmd = sprintf('"%s" activate ts_env && TotalSegmentator -i "%s" -o "%s" -ta total', ...
              anacondaBatPath, inputNifti, outputFolder);

fprintf('=== [Start] ส่งคำสั่งรันระบบไปที่หลังบ้าน ===\n');
fprintf('Command ที่รัน: %s\n\n', cmd);

%% 3. สั่งรันผ่านระบบ Windows หลังบ้านด้วยคำสั่ง system
tic; % เริ่มจับเวลาทำงาน (Time-dependent tracking)
[status, cmdout] = system(cmd);
elapsedTime = toc; % บันทึกเวลาที่ใช้ไป

%% 4. ตรวจสอบผลลัพธ์การทำงาน
if status == 0
    fprintf('=== [Success] โมเดลประมวลผลสำเร็จเรียบร้อย! ===\n');
    fprintf('เวลาที่ใช้ในการประมวลผล: %.2f วินาที\n', elapsedTime);
    
    % สเต็ปถัดไป: สั่งให้ MATLAB เริ่มอ่านไฟล์ที่ได้ด้วย niftiread ได้ทันที
    % example_mask = niftiread(fullfile(outputFolder, 'aorta.nii.gz'));
else
    fprintf('=== [Error] เกิดข้อผิดพลาดในการรันระบบหลังบ้าน ===\n');
    disp(cmdout); % แสดงข้อความ Log แจ้งเตือนความผิดพลาดจากฝั่ง Python ออกมาบนหน้าจอ MATLAB
end
