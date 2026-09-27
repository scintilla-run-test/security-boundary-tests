let
  nixpkgsPath = /tmp/nixpkgs;
  eval = import (nixpkgsPath + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      ./fleet/nixos/scintilla-runtime.nix
      ./fleet/nixos/scintilla-lifecycle-agent.nix
      ({ pkgs, ... }: {
        networking.hostName = "scintilla-proof";
        services.scintillaRuntime = {
          enable = true;
          runnerPackage = pkgs.writeShellScriptBin "scintilla-agent" "exit 0";
          isolationPackage = pkgs.writeShellScriptBin "ores-proc-isolation" "exit 0";
          environment = {
            SCINTILLA_REGION = "proof-region";
            SCINTILLA_CLOUD = "proof-cloud";
          };
        };
        services.scintillaLifecycleAgent = {
          enable = true;
          package = pkgs.writeShellScriptBin "ores-process-lifecycle-agent" "exit 0";
          cluster = "proof-cluster";
          node = "proof-node";
          reconcileSeconds = 17;
        };
      })
    ];
  };
  cfg = eval.config;
in
{
  runtimeEnvironment = cfg.systemd.services.scintilla-runtime.environment;
  runtimeReadWritePaths = cfg.systemd.services.scintilla-runtime.serviceConfig.ReadWritePaths;
  runtimeExtraGroups = cfg.users.users.scintilla.extraGroups;
  lifecycleEnvironment = cfg.systemd.services.scintilla-lifecycle-agent.environment;
  lifecycleUser = cfg.systemd.services.scintilla-lifecycle-agent.serviceConfig.User;
  lifecycleGroup = cfg.systemd.services.scintilla-lifecycle-agent.serviceConfig.Group;
  lifecycleSupplementaryGroups = cfg.systemd.services.scintilla-lifecycle-agent.serviceConfig.SupplementaryGroups;
  lifecycleCapabilities = cfg.systemd.services.scintilla-lifecycle-agent.serviceConfig.CapabilityBoundingSet;
  lifecycleAmbientCapabilities = cfg.systemd.services.scintilla-lifecycle-agent.serviceConfig.AmbientCapabilities;
  lifecycleAddressFamilies = cfg.systemd.services.scintilla-lifecycle-agent.serviceConfig.RestrictAddressFamilies;
  lifecycleProtectControlGroups = cfg.systemd.services.scintilla-lifecycle-agent.serviceConfig.ProtectControlGroups;
  lifecycleReadOnlyPaths = cfg.systemd.services.scintilla-lifecycle-agent.serviceConfig.ReadOnlyPaths;
  lifecycleReadWritePaths = cfg.systemd.services.scintilla-lifecycle-agent.serviceConfig.ReadWritePaths;
  tmpfilesRules = cfg.systemd.tmpfiles.rules;
}
