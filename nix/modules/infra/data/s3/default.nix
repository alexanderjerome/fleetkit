{ config, lib, pkgs, ... }:

# Garage layout + bucket bootstrap — reusable across any host that runs
# services.garage (today only s3, but the helper is upstream so future
# tier-1 storage tiers can reuse it).
#
# Split into two independent oneshots, chained:
#
#   garage.service                       ← upstream module
#     ↓
#   garage-layout-bootstrap.service      ← optional (this module)
#     - reads `garage node id` for the local UUID (no hostname grep)
#     - skips if the local node is already in `garage layout show`
#     - otherwise: assign zone+capacity, apply version 1
#     ↓
#   garage-buckets-bootstrap.service     ← optional (this module)
#     - for each declared bucket name, `bucket info` to check, create
#       if missing
#     - idempotent — re-runs cleanly on every boot
#
# Access keys are intentionally NOT bootstrapped here. Each consuming
# service mints its own (`garage key create <consumer>-key`) and
# stashes the access+secret pair into SOPS at the consumer's path
# (e.g. services/attic/garage_access_key_id). Doing keys at the
# producer side would mean s3 has to know its consumers up front,
# which couples the layers backwards.

let
  cfg = config.infra.data.s3;
in
{
  options.infra.data.s3 = {
    enable = lib.mkEnableOption "Garage layout + bucket bootstrap oneshots";

    environmentFile = lib.mkOption {
      type = lib.types.path;
      example = lib.literalExpression ''config.sops.templates."garage-env".path'';
      description = ''
        Path to the env file carrying GARAGE_RPC_SECRET. Almost always
        the same value the host module passes to
        `services.garage.environmentFile` — set them from the same
        sops.templates."<name>".path so a rotation re-renders both.
      '';
    };

    layout = lib.mkOption {
      default = null;
      description = ''
        Single-node layout to assign on first boot. Set to null on
        multi-node clusters where the operator owns layout out-of-band.
      '';
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          zone = lib.mkOption {
            type = lib.types.str;
            default = "dc1";
            description = "Garage zone label (logical placement region).";
          };
          capacity = lib.mkOption {
            type = lib.types.str;
            example = "500G";
            description = ''
              Capacity advertised for this node (Garage units, e.g.
              "500G", "2T"). Match the disk size of the /data mount.
            '';
          };
        };
      });
    };

    buckets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [ "pg-backups" "pbs-chunkstore" ];
      description = ''
        Bucket names to ensure exist. Idempotent — `bucket info` is
        used to skip already-existing buckets so a re-run on every
        boot is harmless.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.garage-layout-bootstrap = lib.mkIf (cfg.layout != null) {
      description = "Assign + apply Garage cluster layout for the local node";
      after = [ "garage.service" "network-online.target" ];
      requires = [ "garage.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.garage pkgs.gawk ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        EnvironmentFile = [ cfg.environmentFile ];
      };
      script = ''
        set -euo pipefail

        # Wait up to 60s for `garage status` to respond, in case the
        # daemon's RPC isn't immediately ready after start.
        for _ in $(seq 1 30); do
          if garage status >/dev/null 2>&1; then break; fi
          sleep 2
        done

        # `garage node id` returns "<full-id>@<address>" — split on @
        # for the bare node id. More reliable than grepping `status`
        # for the hostname (which can race the daemon's first report).
        NODE_ID="$(garage node id 2>/dev/null | awk -F'@' '{print $1}')"
        if [ -z "$NODE_ID" ]; then
          echo "garage node id returned empty — daemon not ready"
          exit 1
        fi

        # Skip if the layout already lists this node — survives the
        # service restarting on rebuilds. `garage layout show` prints
        # node ids TRUNCATED, so grep on a prefix of the full id from
        # `garage node id` (INFRA-36: the full-id grep never matched,
        # making every re-run fall through to a failing re-assign).
        if garage layout show 2>/dev/null | grep -q "''${NODE_ID:0:16}"; then
          echo "node $NODE_ID already in layout, no-op"
          exit 0
        fi

        echo "assigning layout: zone=${cfg.layout.zone} capacity=${cfg.layout.capacity}"
        garage layout assign -z ${cfg.layout.zone} -c ${cfg.layout.capacity} "$NODE_ID"
        # Layout versions are monotonic — `--version 1` only works on a
        # virgin cluster. Apply current+1 so re-assignment (e.g. after a
        # capacity change) also succeeds.
        CUR_VERSION="$(garage layout show 2>/dev/null \
          | awk '/[Cc]urrent cluster layout version/ {print $NF}')"
        garage layout apply --version "$(( ''${CUR_VERSION:-0} + 1 ))"
      '';
    };

    systemd.services.garage-buckets-bootstrap = lib.mkIf (cfg.buckets != []) {
      description = "Ensure declared Garage buckets exist (idempotent)";
      after =
        [ "garage.service" "network-online.target" ]
        ++ lib.optional (cfg.layout != null) "garage-layout-bootstrap.service";
      requires =
        [ "garage.service" ]
        ++ lib.optional (cfg.layout != null) "garage-layout-bootstrap.service";
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.garage ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        EnvironmentFile = [ cfg.environmentFile ];
      };
      script = ''
        set -euo pipefail

        # Wait until the cluster reports a HEALTHY node — bucket ops
        # against a no-layout cluster fail with a friendly-ish error
        # we'd rather avoid printing.
        for _ in $(seq 1 30); do
          if garage status 2>/dev/null | grep -q -E "HEALTHY|UP"; then break; fi
          sleep 2
        done

        ${lib.concatMapStringsSep "\n" (bucket: ''
          if garage bucket info "${bucket}" >/dev/null 2>&1; then
            echo "bucket ${bucket}: exists"
          else
            echo "bucket ${bucket}: creating"
            garage bucket create "${bucket}"
          fi
        '') cfg.buckets}
      '';
    };
  };
}
