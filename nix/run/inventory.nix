# nix/run/inventory.nix — raw hypervisor inventory dumps (INFRA-31).
#
# Dumps the COMPLETE object graph of both virtualization layers as native
# JSON, exactly as the management APIs return it:
#
#   tier-0  Xen Orchestra REST  (XCP-ng pools/hosts/VMs/SRs/networks/...)
#   tier-1  Proxmox VE API      (cluster status/resources + per-node +
#                                per-guest config)
#
# Usage:
#   nix run .#inventory-dump            # both layers → inventory/raw/{xo,pve}.json
#   nix run .#inventory-dump -- xo      # one layer only
#   nix run .#inventory-dump -- pve
#   nix run .#inventory-dump -- xo --stdout   # print instead of write
#
# Credentials come from SOPS (nix/secrets/secrets.yaml):
#   integrations.xen-orchestra.{url,token}            → XOA_URL / XOA_TOKEN
#   integrations.proxmox.$PVE_SOPS_INSTANCE.{endpoint,api_token} → PVE_ENDPOINT / PVE_TOKEN
# Env vars with those names override SOPS (so CI or another cluster can be
# targeted without editing secrets).
#
# These raw dumps are the source layer for the modular inventory
# (inventory/examples/*.yml shows the target merged shape). Strictly
# read-only — GET requests only, mutations stay with terranix / xo-cli.
#
{ pkgs, lib, nixosConfigurations }:
let
  dumpPy = pkgs.writeText "inventory-dump.py" ''
    """Dump XO + PVE object graphs as raw JSON. Read-only (GET only)."""
    import json, os, ssl, sys, urllib.request

    CTX = ssl._create_unverified_context()  # self-signed certs on both APIs


    def get(url: str, headers: dict) -> object:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, context=CTX, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))


    # ── tier-0: Xen Orchestra REST ────────────────────────────────────────
    # Every inventory-relevant collection, fetched with fields=* so objects
    # come back fully expanded instead of as href lists.
    XO_COLLECTIONS = [
        "pools", "hosts", "vms", "vm-controllers", "vm-templates",
        "vm-snapshots", "srs", "vdis", "vdi-snapshots", "vbds", "vifs",
        "networks", "pifs",
    ]

    def dump_xo() -> dict:
        base = os.environ["XOA_URL"].rstrip("/")
        headers = {"Cookie": "authenticationToken=" + os.environ["XOA_TOKEN"]}
        out = {"meta": {"source": base + "/rest/v0", "layer": "xcp-ng/xo"}}
        for coll in XO_COLLECTIONS:
            print(f"  xo: {coll}…", file=sys.stderr)
            out[coll] = get(f"{base}/rest/v0/{coll}?fields=*", headers)
        return out


    # ── tier-1: Proxmox VE API ────────────────────────────────────────────
    def dump_pve() -> dict:
        base = os.environ["PVE_ENDPOINT"].rstrip("/")
        headers = {"Authorization": "PVEAPIToken=" + os.environ["PVE_TOKEN"]}

        def api(path: str) -> object:
            return get(f"{base}/api2/json{path}", headers)["data"]

        out = {"meta": {"source": base, "layer": "proxmox-ve"}}
        print("  pve: cluster…", file=sys.stderr)
        out["cluster"] = {
            "status": api("/cluster/status"),
            "resources": api("/cluster/resources"),
        }

        online = [n["name"] for n in out["cluster"]["status"]
                  if n["type"] == "node" and n.get("online")]

        out["nodes"] = {}
        for node in sorted(online):
            print(f"  pve: node {node}…", file=sys.stderr)
            out["nodes"][node] = {
                "status": api(f"/nodes/{node}/status"),
                "network": api(f"/nodes/{node}/network"),
                "storage": api(f"/nodes/{node}/storage"),
            }

        # Per-guest config (the full declared shape: rootfs, mounts, nics).
        out["guests"] = {}
        for res in out["cluster"]["resources"]:
            if res["type"] not in ("qemu", "lxc") or res["node"] not in online:
                continue
            vmid, node, kind = res["vmid"], res["node"], res["type"]
            print(f"  pve: {kind}/{vmid} ({res.get('name', '?')})…", file=sys.stderr)
            out["guests"][str(vmid)] = {
                "type": kind,
                "node": node,
                "resource": res,
                "config": api(f"/nodes/{node}/{kind}/{vmid}/config"),
            }
        return out


    def main() -> None:
        targets = [a for a in sys.argv[1:] if not a.startswith("-")] or ["xo", "pve"]
        to_stdout = "--stdout" in sys.argv
        outdir = os.path.join(os.environ.get("INVENTORY_ROOT", "."), "inventory", "raw")

        for target in targets:
            dump = {"xo": dump_xo, "pve": dump_pve}[target]()
            text = json.dumps(dump, indent=2, sort_keys=True)
            if to_stdout:
                print(text)
            else:
                os.makedirs(outdir, exist_ok=True)
                path = os.path.join(outdir, f"{target}.json")
                with open(path, "w") as fh:
                    fh.write(text + "\n")
                print(f"wrote {path} ({len(text) // 1024} KiB)", file=sys.stderr)


    if __name__ == "__main__":
        main()
  '';

  script = pkgs.writeShellScriptBin "inventory-dump" ''
    set -euo pipefail

    ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
    SOPS_FILE="$ROOT/nix/secrets/secrets.yaml"
    export INVENTORY_ROOT="$ROOT"

    if [ -z "''${SOPS_AGE_KEY:-}" ] && [ -z "''${SOPS_AGE_KEY_FILE:-}" ] \
        && [ -f "$HOME/.ssh/sops-age.key" ]; then
      export SOPS_AGE_KEY_FILE="$HOME/.ssh/sops-age.key"
    fi

    # XO credentials (SOPS unless already in env). SOPS stores the
    # websocket URL (wss://) for the Terraform provider; REST lives at
    # https:// on the same host.
    if [ -z "''${XOA_URL:-}" ] || [ -z "''${XOA_TOKEN:-}" ]; then
      _xo=$(${pkgs.sops}/bin/sops -d --extract '["integrations"]["xen-orchestra"]' "$SOPS_FILE")
      export XOA_URL=$(echo "$_xo" | ${pkgs.yq-go}/bin/yq '.url' | ${pkgs.gnused}/bin/sed -e 's|^wss://|https://|' -e 's|^ws://|http://|')
      export XOA_TOKEN=$(echo "$_xo" | ${pkgs.yq-go}/bin/yq '.token')
      unset _xo
    fi

    # PVE cluster credentials (token of the terranix service user).
    if [ -z "''${PVE_ENDPOINT:-}" ] || [ -z "''${PVE_TOKEN:-}" ]; then
      _pve=$(${pkgs.sops}/bin/sops -d --extract "[\"integrations\"][\"proxmox\"][\"''${PVE_SOPS_INSTANCE:?export PVE_SOPS_INSTANCE (provider instance name) or set PVE_ENDPOINT/PVE_TOKEN directly}\"]" "$SOPS_FILE")
      export PVE_ENDPOINT=$(echo "$_pve" | ${pkgs.yq-go}/bin/yq '.endpoint')
      export PVE_TOKEN=$(echo "$_pve" | ${pkgs.yq-go}/bin/yq '.api_token')
      unset _pve
    fi

    exec ${pkgs.python3}/bin/python3 ${dumpPy} "$@"
  '';
in
{
  inventory-dump = script;
}
