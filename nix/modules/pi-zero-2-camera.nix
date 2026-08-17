{ lib, ... }:

{
  # Let the Raspberry Pi firmware identify the official camera and inject the
  # IMX708 + autofocus VCM overlays. Do not also add dtoverlay=imx708 manually.
  hardware.raspberry-pi.config.all.options.camera_auto_detect = {
    enable = true;
    value = true;
  };

  # Camera/ISP/encoder buffers need contiguous memory. 128 MiB is enough for a
  # 1080p pipeline without taking half of the Zero 2 W's 512 MiB from userspace.
  hardware.raspberry-pi.config.all.dt-overlays.vc4-kms-v3d.params.cma-128.enable = true;
  boot.kernelParams = lib.mkAfter [ "cma=128M" ];
}
