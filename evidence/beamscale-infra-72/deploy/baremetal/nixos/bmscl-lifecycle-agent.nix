{ config, lib, ... }:

let
  cfg = config.services.bmsclLifecycleAgent;
  controlGroup = "beamscale-lifecycle-control";
  stateRoot = "/var/lib/beamscale/lifecycle";
  compatibilityCheckpointRoot = "/var/lib/beamscale/lifecycle-disabled-checkpoints";
  managedCgroupRoot = "/sys/fs/cgroup/beamscale-workloads.slice";
  productSocket = "/run/beamscale-lifecycle/control.sock";
  socketDirectory = builtins.dirOf productSocket;
in
{
  options.services.bmsclLifecycleAgent = {
    enable = lib.mkEnableOption "BeamScale external host lifecycle observer/preflight agent";

    package = lib.mkOption {
      type = lib.types.package;
      description = "Pinned package containing ores-process-lifecycle-agent from ores-otel/ores-otel-sidecar.rs.";
    };

    binary = lib.mkOption {
      type = lib.types.str;
      default = "ores-process-lifecycle-agent";
    };

    cluster = lib.mkOption {
      type = lib.types.str;
      description = "Stable BeamScale cluster/cell identity recorded by the shared lifecycle runtime.";
    };

    node = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Stable host/controller identity recorded by the shared lifecycle runtime.";
    };

    controlSocketOwner = lib.mkOption {
      type = lib.types.str;
      description = "Exact OS user that runs bmscl-supervisor and owns the private lifecycle socket directory. This must be supplied by the host deployment; do not guess a tenant or runtime user.";
    };

    reconcileSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 15;
      description = "Observe-only reconciliation cadence while the trusted mutation runtime remains disabled.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Non-secret lifecycle-agent environment only. Distributed lease credentials are intentionally not accepted by this observe-only module.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          builtins.match "^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$" cfg.cluster != null;
        message = "BeamScale lifecycle cluster must be a safe shared-agent identity segment";
      }
      {
        assertion =
          builtins.match "^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$" cfg.node != null;
        message = "BeamScale lifecycle node must be a safe shared-agent identity segment";
      }
      {
        assertion =
          builtins.match "^[A-Za-z_][A-Za-z0-9_-]{0,63}$" cfg.controlSocketOwner != null;
        message = "BeamScale lifecycle controlSocketOwner must be an explicit safe OS user name";
      }
    ];

    users.groups.${controlGroup} = {};

    systemd.slices."beamscale-workloads" = {
      description = "BeamScale suspendable workload processes";
      sliceConfig = {
        CPUAccounting = true;
        MemoryAccounting = true;
        TasksAccounting = true;
      };
    };

    systemd.tmpfiles.rules = [
      "d ${stateRoot} 0700 root root -"
      "d ${compatibilityCheckpointRoot} 0500 root root -"
      "d ${socketDirectory} 2770 ${cfg.controlSocketOwner} ${controlGroup} -"
    ];

    systemd.services.bmscl-lifecycle-agent = {
      description = "BeamScale external host lifecycle observer/preflight agent";
      wantedBy = [ "multi-user.target" ];
      requires = [ "beamscale-workloads.slice" ];
      after = [ "beamscale-workloads.slice" ];

      environment = cfg.environment // {
        ORES_PROCESS_LIFECYCLE_PRODUCT = "beamscale";
        ORES_PROCESS_LIFECYCLE_CLUSTER = cfg.cluster;
        ORES_PROCESS_LIFECYCLE_NODE = cfg.node;
        ORES_PROCESS_LIFECYCLE_STATE_ROOT = stateRoot;
        ORES_PROCESS_LIFECYCLE_CHECKPOINT_ROOT = compatibilityCheckpointRoot;
        ORES_PROCESS_LIFECYCLE_CGROUP_ROOT = managedCgroupRoot;
        ORES_PROCESS_LIFECYCLE_PRODUCT_SOCKET = productSocket;
        ORES_PROCESS_LIFECYCLE_RECONCILE_SECONDS = toString cfg.reconcileSeconds;
        ORES_PROCESS_LIFECYCLE_LEASE_BACKEND = "cloudflare-do";
        ORES_PROCESS_LIFECYCLE_HIBERNATE_ENABLED = "false";
        ORES_PROCESS_LIFECYCLE_EFFECTS_ENABLED = "false";
      };

      serviceConfig = {
        User = "root";
        Group = "root";
        SupplementaryGroups = [ controlGroup ];
        ExecStartPre = "${cfg.package}/bin/${cfg.binary} preflight";
        ExecStart = "${cfg.package}/bin/${cfg.binary}";
        Restart = "always";
        RestartSec = "2s";
        UMask = "0077";

        NoNewPrivileges = true;
        CapabilityBoundingSet = [ ];
        AmbientCapabilities = [ ];
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
        RestrictAddressFamilies = [ "AF_UNIX" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RemoveIPC = true;

        ReadOnlyPaths = [
          "/sys/fs/cgroup"
          compatibilityCheckpointRoot
        ];
        ReadWritePaths = [ stateRoot ];
      };
    };
  };
}
