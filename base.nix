{ config, pkgs, lib, flake, hostname, powerProfile, gpu, cpuVendor, nvidiaBusId, amdBusId, intelBusId, ... }:
let
  isNvidia = builtins.elem gpu [ "nvidia" "prime-nvidia-amd" "prime-nvidia-intel" ];
  isPrime  = builtins.elem gpu [ "prime-nvidia-amd" "prime-nvidia-intel" ];
  isAmdCpu = cpuVendor == "amd";
in
{
  # ── Boot ──────────────────────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable      = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.kernelModules = lib.optionals isNvidia [ "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" ];
  boot.kernelParams = [
    "quiet" "loglevel=3"
    "rd.udev.log_level=3"
    "udev.log_priority=3"
  ] ++ lib.optionals isNvidia [ "nvidia-drm.fbdev=1" ]
    ++ lib.optionals isAmdCpu [ "amd_pstate=active" ];

  # ── Kernel ────────────────────────────────────────────────────────────────────
  boot.kernelPackages                = pkgs.linuxPackages_latest;
  boot.kernelModules                 = [ "tcp_bbr" ];
  boot.extraModulePackages           = [ config.boot.kernelPackages.r8168 ];
  boot.blacklistedKernelModules      = [ "r8169" ];
  boot.kernel.sysctl = {
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.core.default_qdisc"          = "fq";
    "net.core.wmem_max"               = 1073741824;
    "net.core.rmem_max"               = 1073741824;
    "net.ipv4.tcp_rmem"               = "4096 87380 1073741824";
    "net.ipv4.tcp_wmem"               = "4096 87380 1073741824";
    "net.core.netdev_max_backlog"     = 16384;
    "net.ipv4.tcp_fastopen"           = 3;
    "net.ipv4.tcp_mtu_probing"        = 1;
    "net.ipv4.ip_local_port_range"    = "1024 65535";
    "vm.max_map_count"                = 2147483642;
    "net.ipv6.conf.all.use_tempaddr"  = 2;
  };

  # ── Hardware ──────────────────────────────────────────────────────────────────
  services.irqbalance.enable              = true;
  hardware.cpu.amd.updateMicrocode        = lib.mkIf isAmdCpu true;
  powerManagement.cpuFreqGovernor         = if powerProfile == "performance" then "performance"
                                            else if powerProfile == "balanced"   then "schedutil"
                                            else "powersave";

  hardware.graphics.enable               = true;
  hardware.graphics.enable32Bit          = true;
  hardware.graphics.extraPackages        = with pkgs; [
    vulkan-loader
    vulkan-validation-layers
  ];
  hardware.nvidia.modesetting.enable     = lib.mkIf isNvidia true;
  hardware.nvidia.open                   = lib.mkIf isNvidia false;
  hardware.nvidia.nvidiaSettings         = lib.mkIf isNvidia true;
  hardware.nvidia.package                = lib.mkIf isNvidia config.boot.kernelPackages.nvidiaPackages.stable;
  hardware.nvidia.powerManagement.enable = lib.mkIf isNvidia false;
  hardware.nvidia.prime.sync.enable      = lib.mkIf isPrime true;
  hardware.nvidia.prime.nvidiaBusId      = lib.mkIf isPrime nvidiaBusId;
  hardware.nvidia.prime.amdgpuBusId      = lib.mkIf (gpu == "prime-nvidia-amd") amdBusId;
  hardware.nvidia.prime.intelBusId       = lib.mkIf (gpu == "prime-nvidia-intel") intelBusId;
  services.xserver.enable                = false;
  services.xserver.videoDrivers          = lib.mkIf isNvidia [ "nvidia" ];

  # ── Networking ────────────────────────────────────────────────────────────────
  networking.hostName              = hostname;
  networking.networkmanager.enable = true;
  networking.firewall.enable       = true;
  networking.firewall.allowedTCPPorts = [ 22 ];
  networking.extraHosts = ''

'';

  # ── Locale ────────────────────────────────────────────────────────────────────
  time.timeZone    = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── SSH ───────────────────────────────────────────────────────────────────────
  services.openssh = {
    enable                = true;
    settings.PasswordAuthentication = false;
    settings.PermitRootLogin        = "no";
  };

  # ── Packages ──────────────────────────────────────────────────────────────────
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    jq
    bc
    vim
    neovim
    htop
    btop
    tree
    file
    socat
    net-tools
    inetutils
    dig
    nmap
    tcpdump
    wireguard-tools
    openvpn
    python3
    go
    gcc
    docker
    docker-compose
    ansible
    lazygit
    p7zip
    ntp
    busybox
  ];

  # ── Virtualisation ────────────────────────────────────────────────────────────
  virtualisation.docker.enable = true;

  # ── Nix ───────────────────────────────────────────────────────────────────────
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.registry.nixpkgs = { flake = flake; };
  nix.gc = {
    automatic = true;
    dates     = "weekly";
    options   = "--delete-older-than 30d";
  };

  # ── udev ──────────────────────────────────────────────────────────────────────
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", DRIVERS=="usb", ATTR{power/autosuspend}="-1"
  '';

  security.sudo.extraConfig = ''
    Defaults env_keep += "HOME"
  '';

  system.stateVersion = "25.05";
}
