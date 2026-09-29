%% ....Check...nifti 
V = niftiread("P002_Ser3_NonContrast_Standard.nii");
figure;
imagesc(V(:,:,50),[-200 300])
axis image
colormap gray
colorbar

%V = niftiread("P001_Ser5_NonContrast_Standard.nii");

figure;
histogram(V(:),500);
xlim([-2500 2000]);
xlabel('HU');
ylabel('Voxel count');

%% .. 
V = niftiread("P001_Ser5_NonContrast_Standard.nii");

info = niftiinfo("P001_Ser5_NonContrast_Standard.nii");
info.PixelDimensions
info.raw.qform_code
info.raw.sform_code

Vqc = double(V(V > -2000));

[min(Vqc) max(Vqc)]
mean(Vqc,"omitnan")

figure;
histogram(Vqc,500);
xlim([-1200 2000]);
xlabel('HU');
ylabel('Voxel count');

%% ........................
addpath( 'F:/knomjeen_/')
ct = niftiread("P019_Ser2_NonContrast_Standard.nii");
mask1 = niftiread("P019_Ser2_NonContrast_Standard_output_highres\adrenal_gland_left.nii.gz");
mask2 = niftiread("P019_Ser2_NonContrast_Standard_output_highres\adrenal_gland_right.nii.gz");
mask3 = niftiread("P019_Ser2_NonContrast_Standard_output_highres\aorta.nii.gz");
mask4 = niftiread("P019_Ser2_NonContrast_Standard_output_highres\vertebrae_L1.nii.gz");
mask = mask1+mask2+mask3+mask4;
maskCount = squeeze(sum(sum(mask>0,1),2));
[~,k] = max(maskCount);

figure;
imagesc(ct(:,:,k),[-200 300]);
axis image off;
colormap gray;
hold on;

B = bwboundaries(mask(:,:,k)>0);
for i = 1:length(B)
    plot(B{i}(:,2),B{i}(:,1),'LineWidth',1.5);
end
%% ..
ctFile = "P019_Ser2_NonContrast_Standard.nii";

maskFolder = "P019_Ser2_NonContrast_Standard_output_highres";

maskNames = {
    "adrenal_gland_left.nii.gz"
    "adrenal_gland_right.nii.gz"
    "aorta.nii.gz"
    "vertebrae_L1.nii.gz"
    "vertebrae_L2.nii.gz"
    "vertebrae_L3.nii.gz"
    "vertebrae_L4.nii.gz"
    };

info = niftiinfo(ctFile);

dz = info.PixelDimensions(3);
nz = info.ImageSize(3);

fprintf("\nCT: %d slices | dz = %.2f mm | SI coverage ≈ %.1f mm\n\n", ...
    nz,dz,nz*dz);

for i = 1:numel(maskNames)

    f = fullfile(maskFolder,maskNames{i});

    if ~isfile(f)
        fprintf("%-25s : NOT FOUND\n",maskNames{i});
        continue
    end

    M = niftiread(f) > 0;

    sliceCount = squeeze(any(any(M,1),2));

    z = find(sliceCount);

    if isempty(z)
        fprintf("%-25s : EMPTY\n",maskNames{i});
        continue
    end

    z1 = min(z);
    z2 = max(z);

    fprintf("%-25s : slice %3d → %3d   extent = %6.1f mm\n", ...
        maskNames{i},z1,z2,(z2-z1+1)*dz);

end
%% .....
k = round(size(ct,3)/2);

figure;
imagesc(ct(:,:,k),[-200 300]);
axis image off;
colormap gray;
hold on;

B = bwboundaries(mask(:,:,k)>0);
for i = 1:length(B)
    plot(B{i}(:,2),B{i}(:,1),'LineWidth',1.5);
end

title(sprintf('Slice %d',k));