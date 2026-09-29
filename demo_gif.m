addpath('F:/knomjeen_/')

ct = niftiread("P019_Ser2_NonContrast_Standard.nii");

mask1 = niftiread("P019_Ser2_NonContrast_Standard_output_highres\adrenal_gland_left.nii.gz");
mask2 = niftiread("P019_Ser2_NonContrast_Standard_output_highres\adrenal_gland_right.nii.gz");
mask3 = niftiread("P019_Ser2_NonContrast_Standard_output_highres\aorta.nii.gz");
mask4 = niftiread("P019_Ser2_NonContrast_Standard_output_highres\vertebrae_L1.nii.gz");
mask5 = niftiread("P019_Ser2_NonContrast_Standard_output_highres\vertebrae_L2.nii.gz");
mask6 = niftiread("P019_Ser2_NonContrast_Standard_output_highres\vertebrae_L3.nii.gz");
mask7 = niftiread("P019_Ser2_NonContrast_Standard_output_highres\vertebrae_L4.nii.gz");

mask = mask1 + mask2 + mask3 + mask4 + mask5 + mask6 + mask7 ;

maskCount = squeeze(sum(sum(mask>0,1),2));
z = find(maskCount > 0);

zStart = min(z);
zEnd   = max(z);

gifFile = "P019_TotalSeg_Demo.gif";

fig = figure('Color','w','Position',[100 100 650 650]);

for k = zStart:zEnd

    clf(fig)

    imagesc(ct(:,:,k),[-200 300]);
    axis image off
    colormap gray
    hold on

    B = bwboundaries(mask(:,:,k)>0);

    for i = 1:length(B)
        plot(B{i}(:,2),B{i}(:,1),'LineWidth',2);
    end

    title(sprintf('P019 | TotalSegmentator Demo | Slice %d/%d', ...
        k,size(ct,3)), ...
        'FontSize',14,'FontWeight','bold');

    drawnow

    frame = getframe(gcf);
    im = frame2im(frame);
    [A,map] = rgb2ind(im,256);

    if k == zStart
        imwrite(A,map,gifFile,'gif', ...
            'LoopCount',Inf,...
            'DelayTime',0.12);
    else
        imwrite(A,map,gifFile,'gif', ...
            'WriteMode','append',...
            'DelayTime',0.12);
    end
end

disp("Demo GIF saved: " + gifFile)