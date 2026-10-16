{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib.attrsets)
    filterAttrs
    optionalAttrs
    ;
  inherit (lib.lists)
    filter
    map
    optional
    optionals
    ;
  inherit (lib.modules)
    mkIf
    mkMerge
    ;
  inherit (lib.options) mkEnableOption mkOption;

  cfg = config.programs.steam-asahi;
  launcherTypes = (import ../../lib/launcher/options.nix { inherit lib; }).types;

  # Both backends are installed. `backend` chooses which one the plain
  # `steam-asahi` command and the default menu entry start
  backendPackages = {
    x86-fex = pkgs.steam-asahi;
    arm64 = pkgs.steam-asahi-arm64;
  };
  otherBackend = if cfg.backend == "arm64" then "x86-fex" else "arm64";

  backendEnvironments = import ../../lib/launcher/environments.nix;

  # Module values reach every installed backend. Each package keeps its own
  # defaults, and only the arm64 package receives the arm64-only arguments
  withModuleValues =
    backend: package:
    package.override (
      previous:
      {
        inherit (cfg) cpuList memoryMiB vramMiB;
        # Match nixpkgs' Steam module by preserving customization already applied
        # to the package. Backend defaults sit above it, and module values win per
        # variable. Null continues to mean removal
        extraEnv = filterAttrs (_: value: value != null) (
          (previous.extraEnv or { }) // backendEnvironments.${backend} // cfg.extraEnv
        );
        inherit publishPorts;
      }
      // optionalAttrs (backend == "arm64") {
        inherit (cfg) customSteamHomeDir;
        x86Games = map toString cfg.x86Games;
      }
    );

  otherPackage = withModuleValues otherBackend backendPackages.${otherBackend};

  # The plain command and the default menu entry, which owns steam:// links
  defaultLauncher = pkgs.writeShellApplication {
    name = "steam-asahi";
    inheritPath = false;
    text = ''
      exec ${lib.meta.getExe cfg.package} "$@"
    '';
  };
  defaultDesktopItem = pkgs.makeDesktopItem {
    name = "steam-asahi";
    desktopName = "Steam (Asahi)";
    comment =
      if cfg.backend == "arm64" then
        "Native ARM64 Steam public beta in a 4K-page microVM"
      else
        "Steam on Apple Silicon via muvm + FEX-Emu";
    exec = "steam-asahi %U";
    icon = "steam";
    startupNotify = true;
    categories = [
      "Game"
      "Network"
    ];
    mimeTypes = [
      "x-scheme-handler/steam"
      "x-scheme-handler/steamlink"
    ];
  };

  hasPulseAudioServer =
    config.services.pulseaudio.enable
    || (config.services.pipewire.enable && config.services.pipewire.pulse.enable);

  mkPort = protocol: port: { inherit protocol port; };
  mkPortRange = protocol: from: to: { inherit protocol from to; };

  # Derive host firewall rules and muvm/passt publications from the same ports
  steamPorts =
    optionals (cfg.remotePlay.openFirewall || cfg.localNetworkGameTransfers.openFirewall) [
      (mkPort "udp" 27036) # Peer discovery
    ]
    ++ optionals cfg.remotePlay.openFirewall [
      (mkPort "tcp" 27036)
      (mkPort "tcp" 27037)
      (mkPort "udp" 10400)
      (mkPort "udp" 10401)
      (mkPortRange "udp" 27031 27035)
    ]
    ++ optionals cfg.dedicatedServer.openFirewall [
      (mkPort "tcp" 27015) # SRCDS Rcon
      (mkPort "udp" 27015) # Gameplay
    ]
    ++ optionals cfg.localNetworkGameTransfers.openFirewall [
      (mkPort "tcp" 27040) # Data transfers
    ];

  singlePortsFor =
    protocol:
    map (specification: specification.port) (
      filter (specification: specification.protocol == protocol && specification ? port) steamPorts
    );

  portRangesFor =
    protocol:
    map (specification: {
      inherit (specification) from to;
    }) (filter (specification: specification.protocol == protocol && specification ? from) steamPorts);

  # muvm uses passt for guest networking, so opening the host firewall alone is
  # insufficient. Publish the selected ports from the guest to the host too
  publishPorts = map (
    specification:
    let
      endpoint =
        if specification ? port then
          toString specification.port
        else
          "${toString specification.from}-${toString specification.to}";
    in
    "${endpoint}/${specification.protocol}"
  ) steamPorts;

  # muvm marks proxied PipeWire portal clients with a private access property
  # Its matching WirePlumber policy lives in the source tree but is not
  # installed by nixpkgs' muvm package, so expose that exact-version policy as
  # a normal NixOS WirePlumber config package
  muvmWirePlumberConfig = pkgs.runCommand "muvm-wireplumber-config-${pkgs.muvm.version}" { } ''
    mkdir -p "$out/share/wireplumber"
    cp -R ${pkgs.muvm.src}/share/wireplumber/. "$out/share/wireplumber/"
  '';
in
{
  _class = "nixos";

  options.programs.steam-asahi = {
    enable = mkEnableOption "Steam on Apple Silicon in a 4K-page microVM";

    backend = mkOption {
      type = lib.types.enum [
        "x86-fex"
        "arm64"
      ];
      default = "x86-fex";
      description = ''
        Backend behind the plain `steam-asahi` command and the default menu
        entry. Both backends stay installed, so `steam-asahi-arm64` and
        `steam-asahi-x86` start either client without a rebuild. `x86-fex` runs
        the established x86 client through FEX, while `arm64` runs Valve's
        experimental native ARM64 public beta. Both use muvm because Asahi hosts
        use 16K pages while Valve's binaries currently require a conventional
        4K-page environment.
      '';
    };

    package = mkOption {
      type = lib.types.package;
      default = backendPackages.${cfg.backend};
      defaultText = lib.options.literalExpression ''
        if config.programs.steam-asahi.backend == "arm64" then
          pkgs.steam-asahi-arm64
        else
          pkgs.steam-asahi
      '';
      apply = withModuleValues cfg.backend;
      description = ''
        The Steam Asahi launcher package to use. The package is overridden with
        {option}`programs.steam-asahi.cpuList`,
        {option}`programs.steam-asahi.memoryMiB`,
        {option}`programs.steam-asahi.vramMiB`, and
        {option}`programs.steam-asahi.extraEnv`, plus the guest ports selected
        by the firewall options. The ARM64 backend also receives
        {option}`programs.steam-asahi.customSteamHomeDir`. Existing `extraEnv`
        customization on the selected package is preserved, while module
        values take precedence. A custom package must accept the corresponding
        arguments.
      '';
    };

    customSteamHomeDir = mkOption {
      type = launcherTypes.customSteamHomeDir;
      default = null;
      example = "steam-asahi-arm64-test-home";
      description = ''
        Custom HOME for the native ARM64 Steam beta. When this is `null`, the
        launcher uses `$XDG_DATA_HOME/steam-asahi-arm64-home` (normally
        `~/.local/share/steam-asahi-arm64-home`). A relative value is resolved
        below the user's original XDG data directory; an absolute value is used
        as-is. Steam's client files, games, compatibility tools, Proton
        prefixes, shader caches, and per-user configuration remain below this
        HOME.

        This option is passed to custom packages only for the `arm64` backend.
      '';
    };

    cpuList = mkOption {
      type = launcherTypes.cpuList;
      default = null;
      example = [
        0
        1
        2
        3
        4
        5
        6
        7
      ];
      description = ''
        Host logical CPU IDs on which muvm may run. Each ID also creates one
        guest vCPU. When this is `null`, muvm uses its upstream default: the
        host's performance cores only on a heterogeneous Apple SoC.

        Including efficiency cores can improve highly parallel throughput, but
        the guest cannot distinguish performance and efficiency vCPUs. It can
        therefore reduce frame-time consistency or single-thread performance.
        Compare per-game results before keeping a non-default list. Host and
        guest CPU numbers are unrelated; inspect the host IDs with
        {command}`lscpu -e=CPU,MAXMHZ`.
      '';
    };

    memoryMiB = mkOption {
      type = launcherTypes.memoryMiB;
      default = null;
      example = 6144;
      description = ''
        Ceiling for the microVM memory in MiB. When this is `null`, muvm uses
        its default of 80% of total RAM. The ceiling is not reserved up front:
        memory is provided on demand and returned to the host through
        virtio-balloon free-page reporting. On an 8 GiB machine, 6144 MiB
        leaves useful headroom for the host compositor.
      '';
    };

    vramMiB = mkOption {
      type = launcherTypes.vramMiB;
      default = null;
      example = 4096;
      description = ''
        Video-memory heap size in MiB reported by the Asahi userspace driver
        inside the microVM. When this is `null`, muvm reports half of total host
        RAM. This controls the driver's `HK_SYSMEM` value; it does not reserve
        that amount of physical memory up front.
      '';
    };

    x86Games = mkOption {
      type = lib.types.listOf lib.types.ints.positive;
      default = [ ];
      example = [ 1158310 ];
      description = ''
        Steam AppIDs that run only on the x86/FEX backend. The ARM64 client does
        not export menu entries for them, so its menu cannot start them. Add
        their shortcuts from the x86 client; the x86 launcher repairs those
        shortcuts to run `steam-asahi-x86`.
      '';
    };

    installedPackages = mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      internal = true;
      default = {
        x86-fex = if cfg.backend == "x86-fex" then cfg.package else otherPackage;
        arm64 = if cfg.backend == "arm64" then cfg.package else otherPackage;
      };
      description = "Launcher packages installed for each backend.";
    };

    extraEnv = mkOption {
      type = launcherTypes.extraEnv;
      default = { };
      example = {
        MANGOHUD = "1";
        FEX_MULTIBLOCK = null;
      };
      description = ''
        Environment variables exported inside every installed backend. Names
        must be valid shell variable names, such as `MANGOHUD` or `STEAMOS`.
        Each backend keeps its own defaults, and these values are merged per
        variable on top of them. Set a variable to `null` to remove it from every
        backend. For example, `FEX_MULTIBLOCK = null` removes the x86 default and
        leaves the ARM64 backend unchanged.
      '';
    };

    remotePlay.openFirewall = mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open the host firewall and publish the microVM ports needed for Steam
        Remote Play.
      '';
    };

    dedicatedServer.openFirewall = mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open the host firewall and publish the microVM ports needed for Source
        Dedicated Server.
      '';
    };

    localNetworkGameTransfers.openFirewall = mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open the host firewall and publish the microVM ports needed for Steam
        Local Network Game Transfers.
      '';
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      assertions = [
        {
          assertion = pkgs.stdenv.hostPlatform.system == "aarch64-linux";
          message = "`programs.steam-asahi` is supported only on aarch64-linux.";
        }
        {
          assertion = !config.programs.steam.enable;
          message = ''
            `programs.steam-asahi` conflicts with `programs.steam`. Disable the
            regular Steam module; Steam Asahi provides its own client and does
            not use host 32-bit graphics.
          '';
        }
        {
          assertion = !config.hardware.graphics.enable32Bit;
          message = ''
            `programs.steam-asahi` conflicts with
            `hardware.graphics.enable32Bit`. Both backends use 64-bit host
            graphics; x86 support is contained inside the guest.
          '';
        }
      ];

      warnings =
        optional (!hasPulseAudioServer) ''
          `programs.steam-asahi` expects a PulseAudio-compatible socket, but
          neither PipeWire with `services.pipewire.pulse.enable` nor
          `services.pulseaudio.enable` is enabled. Steam may have no audio.
        ''
        ++ optional (config.users.groups.kvm.members == [ ]) ''
          `programs.steam-asahi` requires access to `/dev/kvm`, but no users
          belong to the `kvm` group. Add each trusted user with
          `users.users.<name>.extraGroups = [ "kvm" ];`.
        '';

      environment.systemPackages = [
        defaultLauncher
        defaultDesktopItem
        cfg.package
        otherPackage
        # Useful for direct guest diagnostics documented in the README. The
        # launcher's other dependencies are already referenced by its closure
        pkgs.muvm
      ];

      # Host Mesa/virglrenderer provides Asahi DRM native-context rendering;
      # steam-hardware supplies the standard controller and input udev rules
      hardware.graphics.enable = true;
      hardware.steam-hardware.enable = true;

      services.pipewire.wireplumber.configPackages =
        optionals config.services.pipewire.wireplumber.enable
          [ muvmWirePlumberConfig ];

      # These match nixpkgs' regular Steam module. The launcher additionally
      # forwards each enabled port through muvm/passt
      networking.firewall = {
        allowedTCPPorts = singlePortsFor "tcp";
        allowedUDPPorts = singlePortsFor "udp";
        allowedTCPPortRanges = portRangesFor "tcp";
        allowedUDPPortRanges = portRangesFor "udp";
      };
    })
  ];
}
