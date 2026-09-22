{ config, pkgs, lib, flake, nur, hostname, powerProfile, gpu, cpuVendor, nvidiaBusId, amdBusId, intelBusId, ... }:
let
  isNvidia = builtins.elem gpu [ "nvidia" "prime-nvidia-amd" "prime-nvidia-intel" ];
  isPrime  = builtins.elem gpu [ "prime-nvidia-amd" "prime-nvidia-intel" ];
  isAmdCpu = cpuVendor == "amd";
  nurPkgs  = nur.legacyPackages.${pkgs.system};
in
{
  # ── Boot ──────────────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable      = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.kernelModules = lib.optionals isNvidia [ "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" ];
  boot.kernelParams = [
    "quiet" "loglevel=3"
    "rd.systemd.show_status=false"
    "rd.udev.log_level=3"
    "udev.log_priority=3"
    "tsc=reliable"
  ] ++ lib.optionals isNvidia [ "nvidia-drm.fbdev=1" ]
    ++ lib.optionals isAmdCpu [ "amd_pstate=active" ];
  boot.consoleLogLevel = 0;
  boot.initrd.verbose  = false;

  # ── Kernel ────────────────────────────────────────────────────────────
  boot.kernelPackages           = pkgs.linuxPackages_latest;
  boot.kernelModules            = [ "tcp_bbr" ];
  boot.extraModulePackages      = [ config.boot.kernelPackages.r8168 ];
  boot.blacklistedKernelModules = [ "r8169" ];
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

  # ── Hardware ──────────────────────────────────────────────────────────
  services.irqbalance.enable       = true;
  hardware.cpu.amd.updateMicrocode = lib.mkIf isAmdCpu true;
  powerManagement.cpuFreqGovernor  = if powerProfile == "performance" then "performance"
                                     else if powerProfile == "balanced"   then "schedutil"
                                     else "powersave";

  hardware.graphics.enable = lib.mkIf isNvidia true;  # needed for nvidia kernel driver even headless
  hardware.nvidia.modesetting.enable          = lib.mkIf isNvidia true;
  hardware.nvidia.open                        = lib.mkIf isNvidia false;
  hardware.nvidia.nvidiaSettings              = lib.mkIf isNvidia true;
  hardware.nvidia.package                     = lib.mkIf isNvidia config.boot.kernelPackages.nvidiaPackages.stable;
  hardware.nvidia.powerManagement.enable      = lib.mkIf isNvidia false;
  hardware.nvidia.powerManagement.finegrained = lib.mkIf isNvidia false;
  hardware.nvidia.prime.sync.enable           = lib.mkIf isPrime true;
  hardware.nvidia.prime.nvidiaBusId           = lib.mkIf isPrime nvidiaBusId;
  hardware.nvidia.prime.amdgpuBusId           = lib.mkIf (gpu == "prime-nvidia-amd") amdBusId;
  hardware.nvidia.prime.intelBusId            = lib.mkIf (gpu == "prime-nvidia-intel") intelBusId;
  services.xserver.enable                     = false;
  services.xserver.videoDrivers              = lib.mkIf isNvidia [ "nvidia" ];

  # ── Networking ────────────────────────────────────────────────────────
  networking.hostName                           = hostname;
  networking.networkmanager.enable              = true;
  networking.networkmanager.ethernet.macAddress = "random";
  networking.firewall.enable                    = true;
  networking.firewall.allowedTCPPorts           = [ 22 ];
  networking.extraHosts = ''

'';

  # ── Locale ────────────────────────────────────────────────────────────
  time.timeZone      = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── SSH ───────────────────────────────────────────────────────────────
  services.openssh = {
    enable                          = true;
    settings.PasswordAuthentication = false;
    settings.PermitRootLogin        = "no";
  };

  # ── Shell ─────────────────────────────────────────────────────────────
  programs.zsh.enable = true;

  # ── Packages ──────────────────────────────────────────────────────────
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
    fzf
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
    zsh
    speedtest-go
    nurPkgs.repos.sh0rtround.nix-easy-search
  ];

  # ── Virtualisation ────────────────────────────────────────────────────
  virtualisation.docker.enable   = true;
  virtualisation.libvirtd.enable = true;

  # ── Power profiles ────────────────────────────────────────────────────
  services.power-profiles-daemon.enable = true;
  # power-profiles-daemon ships WantedBy=graphical.target which never fires
  # without a display manager. Pull into multi-user.target so it starts at boot.
  systemd.services.power-profiles-daemon = {
    overrideStrategy = "asDropin";
    wantedBy         = [ "multi-user.target" ];
  };
  # Lock power profile statically — set powerProfile in config.nix to change it.
  systemd.services.static-power-profile = {
    description = "Lock power profile to ${powerProfile}";
    after       = [ "multi-user.target" "power-profiles-daemon.service" ];
    wants       = [ "power-profiles-daemon.service" ];
    wantedBy    = [ "multi-user.target" ];
    serviceConfig = {
      Type         = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 2";
      ExecStart    = "${pkgs.power-profiles-daemon}/bin/powerprofilesctl set ${powerProfile}";
    };
  };

  # ── udev ──────────────────────────────────────────────────────────────
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", DRIVERS=="usb", ATTR{power/autosuspend}="-1"
    ACTION=="change", SUBSYSTEM=="power_supply", ATTR{type}=="Mains", RUN+="${pkgs.systemd}/bin/systemctl restart static-power-profile.service"
  '';

  # ── Nix ───────────────────────────────────────────────────────────────
  security.sudo.extraConfig = ''
    Defaults env_keep += "HOME"
  '';
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.registry.nixpkgs = { flake = flake; };
  nix.gc = {
    automatic = true;
    dates     = "weekly";
    options   = "--delete-older-than 30d";
  };

  system.stateVersion = "25.05";
}
