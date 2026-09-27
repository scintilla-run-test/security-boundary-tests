{ config, lib, pkgs, ... }:

let
  cfg = config.services.scintillaRuntime;
in
{
  options.services.scintillaRuntime = {
    enable = lib.mkEnableOption "Scintilla bare-process runtime host";
    runnerPackage = lib.mkOption {
      type = lib.types.package;
      description = "Immutable package containing the Scintilla runtime agent.";
    };
    runnerBinary = lib.mkOption {
      type = lib.types.str;
      default = "scintilla-agent";
    };
    isolationPackage = lib.mkOption {
      type = lib.types.package;
      description = "Pinned ORESoftware ores-proc-isolation-cli package.";
    };
    isolationBinary = lib.mkOption {
      type = lib.types.str;
      default = "ores-proc-isolation";
    };
    bundleRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/scintilla/bundles";
    };
    stateRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/scintilla";
    };
    runtimeUser = lib.mkOption {
      type = lib.types.str;
      default = "scintilla";
    };
    credentialFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Runtime credential name to host path; values stay outside the Nix store.";
    };
    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Non-secret runtime environment only. Distributed lifecycle lease/checkpoint authority is intentionally not accepted here.";
    };
    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "80%";
    };
    cpuQuota = lib.mkOption {
      type = lib.types.str;
      default = "800%";
    };
    tasksMax = lib.mkOption {
      type = lib.types.int;
      default = 32768;
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.scintilla = {};
    users.users.${cfg.runtimeUser} = {
      isSystemUser = true;
      group = "scintilla";
      home = cfg.stateRoot;
      createHome = true;
    };

    environment.systemPackages = [
      cfg.runnerPackage
      cfg.isolationPackage
      pkgs.bubblewrap
      pkgs.slirp4netns
      pkgs.iproute2
      pkgs.nftables
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stateRoot} 0750 ${cfg.runtimeUser} scintilla -"
      "d ${cfg.bundleRoot} 0750 ${cfg.runtimeUser} scintilla -"
    ];

    systemd.services.scintilla-runtime = {
      description = "Scintilla bare-process runtime agent";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      environment = cfg.environment // {
        SCINTILLA_EXECUTOR = "process";
        SCINTILLA_BUNDLE_ROOT = cfg.bundleRoot;
        SCINTILLA_ISOLATION_BINARY = "${cfg.isolationPackage}/bin/${cfg.isolationBinary}";
      };

      serviceConfig = {
        User = cfg.runtimeUser;
        Group = "scintilla";
        ExecStart = "${cfg.runnerPackage}/bin/${cfg.runnerBinary}";
        Restart = "on-failure";
        RestartSec = "2s";
        LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") cfg.credentialFiles;

        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        ProcSubset = "pid";
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RemoveIPC = true;
        UMask = "0077";

        ReadWritePaths = [ cfg.stateRoot ];
        MemoryMax = cfg.memoryMax;
        CPUQuota = cfg.cpuQuota;
        TasksMax = cfg.tasksMax;
        LimitNOFILE = 65536;
      };
    };
  };
}
