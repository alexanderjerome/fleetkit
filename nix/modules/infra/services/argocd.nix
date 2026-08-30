{ config, pkgs, lib, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types optionals optionalAttrs;
  cfg = config.infra.argocd;

  hostsLib = import ../../../lib/inventory.nix { hosts = config.fleet.hostsJson; };
  sopsLib  = import ../../../lib/sops.nix { inherit lib; };
  clusterIps = hostsLib.ipsByCluster cfg.clusterName;
  isServer = cfg.nodeIndex == 0;

  serverIp =
    if clusterIps != [] then builtins.head clusterIps
    else "${cfg.clusterName}-0-pending";

  tokenSecret = "integrations/${cfg.clusterName}/k3s_token";
in
# ArgoCD cluster — k3s with ArgoCD for GitOps workloads.
# Node 0 = server (control plane + ArgoCD), nodes 1+ = agents.
#
# Bootstrap: fleet secrets cluster-token <cluster-name>
{
  options.infra.argocd = {
    enable = mkEnableOption "ArgoCD cluster node (k3s + ArgoCD)";

    clusterName = mkOption {
      type = types.str;
      default = "argocd";
      description = "Logical cluster name. Used for token lookup and IP discovery.";
    };

    nodeIndex = mkOption {
      type = types.int;
      default = 0;
      description = "Node index within the cluster. 0 = server, 1+ = agents.";
    };

    argocdVersion = mkOption {
      type = types.str;
      default = "7.7.15";
      description = "Argo CD Helm chart version.";
    };
  };

  config = mkIf cfg.enable {
    sops.secrets.${tokenSecret} = sopsLib.mkSecret {
      restartUnits = [ "k3s.service" ];
    };

    services.k3s = {
      enable = true;
      role = if isServer then "server" else "agent";
      tokenFile = config.sops.secrets.${tokenSecret}.path;
      extraFlags = builtins.concatStringsSep " " ([
        "--data-dir /data/k3s"
      ] ++ (if isServer then [
        "--disable traefik"
        "--write-kubeconfig-mode 644"
      ] else [
        "--server https://${serverIp}:6443"
      ]));
    };

    systemd.tmpfiles.rules = optionals isServer [
      "d /data/k3s/server/manifests 0755 root root -"
    ];

    environment.etc = optionalAttrs isServer {
      "rancher/k3s/server/manifests/argocd-namespace.yaml" = {
        text = ''
          apiVersion: v1
          kind: Namespace
          metadata:
            name: argocd
        '';
      };
      "rancher/k3s/server/manifests/argocd-install.yaml" = {
        text = ''
          apiVersion: helm.cattle.io/v1
          kind: HelmChart
          metadata:
            name: argocd
            namespace: kube-system
          spec:
            repo: https://argoproj.github.io/argo-helm
            chart: argo-cd
            version: "${cfg.argocdVersion}"
            targetNamespace: argocd
            createNamespace: true
            valuesContent: |-
              server:
                service:
                  type: NodePort
                  nodePortHttp: 30080
                  nodePortHttps: 30443
        '';
      };
    };

    environment.systemPackages = with pkgs; [
      kubectl
      kubernetes-helm
    ] ++ optionals isServer [
      argocd
    ];

    networking.firewall.allowedTCPPorts = [
      6443    # k3s API server
      10250   # kubelet
    ] ++ optionals isServer [
      30080   # ArgoCD HTTP (NodePort)
      30443   # ArgoCD HTTPS (NodePort)
    ];
  };
}
