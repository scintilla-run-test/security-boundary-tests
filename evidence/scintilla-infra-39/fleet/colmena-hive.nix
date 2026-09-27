{ nixpkgs
, nodes
, runnerPackage
, isolationPackage
, lifecycleAgentPackage ? null
, extraModules ? []
}:

let
  lib = nixpkgs.lib;
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  mkNode = name: node: {
    deployment = {
      targetHost = node.targetHost;
      targetUser = node.targetUser or "root";
      tags = [ (node.region or "unknown") (node.cloud or "unknown") ];
    };

    imports = [
      ./nixos/scintilla-runtime.nix
      ./nixos/scintilla-lifecycle-agent.nix
    ] ++ extraModules;
    networking.hostName = name;

    services.scintillaRuntime = {
      enable = true;
      inherit runnerPackage isolationPackage;
      environment = {
        SCINTILLA_REGION = node.region or "unknown";
        SCINTILLA_CLOUD = node.cloud or "unknown";
      } // (node.environment or {});
      credentialFiles = node.credentialFiles or {};
    };

    services.scintillaLifecycleAgent = lib.mkIf (lifecycleAgentPackage != null) {
      enable = true;
      package = lifecycleAgentPackage;
      cluster = node.lifecycleCluster or "scintilla-${node.region or "unknown"}";
      node = name;
      reconcileSeconds = node.lifecycleReconcileSeconds or 15;
    };
  };
in
{
  meta = { nixpkgs = pkgs; };
} // lib.mapAttrs mkNode nodes
