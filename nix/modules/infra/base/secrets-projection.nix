{ config, lib, ... }:

# fleet.secrets → sops.secrets projection (ADR-096 A5).
#
# Every fleet.secrets instance naming THIS host in consumers.hosts
# materialises as sops.secrets."<resource>/<instance>/<sname>", keyed as
# "<instance>/<sname>" inside the resource's OWN encrypted file. Nothing
# else of the resource reaches the host: operator- and tofu-consumed
# instances never land anywhere by construction, which is the point of
# declaring consumers instead of assuming host delivery.
#
# consumers.hosts entries are FLEET KEYS. The current key is resolved by
# matching this host's hostname back through hostsJson — they differ on
# tier-1 hosts, where the key is `pve-data` but the hostname is
# `data.example.pve`. Its own module file because fleet-member already
# defines sops.secrets entries and a shorthand module cannot repeat the
# key.
let
  hn = config.networking.hostName;
  myKey =
    let hits = lib.filterAttrs (_: e: (e.hostname or "") == hn)
                 (config.fleet.hostsJson or {});
    in if hits != {} then lib.head (lib.attrNames hits) else hn;

  pairs = lib.concatLists (lib.mapAttrsToList (rname: r:
    lib.concatLists (lib.mapAttrsToList (iname: inst:
      let cons = inst.consumers or r.consumers or {};
      in lib.optionals (lib.elem myKey (cons.hosts or []))
        (lib.mapAttrsToList (sname: sdef:
          lib.nameValuePair "${rname}/${iname}/${sname}"
            ({ sopsFile = r.file; key = "${iname}/${sname}"; }
             // lib.filterAttrs (n: _: lib.elem n [ "owner" "group" "mode" "restartUnits" ])
                  (if builtins.isAttrs sdef then sdef else {})))
          (inst.secrets or {})))
      (r.instances or {})))
    (config.fleet.secrets or {}));
in
{
  config.sops.secrets = lib.listToAttrs pairs;
}
