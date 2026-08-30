# Helpers for querying the fleet host inventory.
# Standalone file — can be imported from shell.nix, secrets, or any module
# without circular dependencies.
#
# Phase N: input is the evaluated fleet module's hostsJson shape passed
# directly, not a file read from .cache/sk/hosts.json.  Callers that don't
# want to eval fleet themselves can fall back to reading the generated
# `packages.hostsJson` output from disk.
{
  hosts ? null,           # preferred: pass fleet.hostsJson directly
  hostsFile ? null,        # legacy: path to a hosts.json dump (optional)
  cacheKeyFile ? ../secrets/secrets/keys/builder-cache-pub-key.pem,
}:

let
  allHosts =
    if hosts != null then hosts
    else if hostsFile != null then builtins.fromJSON (builtins.readFile hostsFile)
    else throw "nix/lib/inventory.nix: supply either `hosts` (fleet attrset) or `hostsFile`";

  # Format-agnostic accessors
  _isRich = h: h ? properties;

  _ip = h:
    if _isRich h then (h.properties.ipv4 or {}).eth0 or ""
    else h.ip or "";

  _internalIp = h:
    if _isRich h then (h.properties.ipv4 or {}).eth1 or ""
    else h.internal_ip or "";

  _tags = h:
    if _isRich h then h.properties.tags or []
    else h.tags or [];

  _cluster = h:
    if _isRich h then h.cluster or ""
    else h.cluster or "";

  _nodeIndex = h:
    if _isRich h then h.nodeIndex or 0
    else h.node_index or 0;

  _hasIp = h: (_ip h) != "";
in
{
  # All hosts as an attrset (raw from hosts.json)
  all = allHosts;

  # Find hosts matching a tag, filtered for non-empty IPs.
  # Returns a list of host attrsets.
  byTag = tag:
    builtins.filter
      (h: builtins.elem tag (_tags h) && _hasIp h)
      (builtins.attrValues allHosts);

  # Get the IP of the first host matching a tag, or null if none found.
  ipByTag = tag:
    let
      matches = builtins.filter
        (h: builtins.elem tag (_tags h) && _hasIp h)
        (builtins.attrValues allHosts);
    in
      if matches != [] then _ip (builtins.head matches) else null;

  # Find all hosts belonging to a specific cluster, sorted by node_index.
  # Returns a list of host attrsets.
  byCluster = clusterName:
    let
      matches = builtins.filter
        (h: (_cluster h) == clusterName && _hasIp h)
        (builtins.attrValues allHosts);
    in
      builtins.sort (a: b: (_nodeIndex a) < (_nodeIndex b)) matches;

  # Get IPs for all nodes in a cluster, ordered by node_index.
  ipsByCluster = clusterName:
    let
      matches = builtins.filter
        (h: (_cluster h) == clusterName && _hasIp h)
        (builtins.attrValues allHosts);
      sorted = builtins.sort (a: b: (_nodeIndex a) < (_nodeIndex b)) matches;
    in
      builtins.map (h: _ip h) sorted;

  # Builder binary cache configuration.
  # Returns { url, publicKey } if the builder has an IP and its public key
  # file exists, or null otherwise. Used by base.nix and shell.nix.
  builderCache =
    let
      builderIp =
        let
          matches = builtins.filter
            (h: builtins.elem "builder" (_tags h) && ((_ip h) != "" || (_internalIp h) != ""))
            (builtins.attrValues allHosts);
          best = h: let ip = _ip h; iip = _internalIp h; in
            if ip != "" then ip else iip;
        in
          if matches != [] then best (builtins.head matches) else null;
      keyExists = builtins.pathExists cacheKeyFile;
      publicKey =
        if keyExists
        then builtins.replaceStrings ["\n"] [""] (builtins.readFile cacheKeyFile)
        else null;
    in
      if builderIp != null && publicKey != null
      then { url = "http://${builderIp}:5000"; inherit publicKey; }
      else null;
}
