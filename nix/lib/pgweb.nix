# pgweb configuration constructor (INFRA-42).
#
# Single source of truth for how a Postgres host advertises itself to
# the fleet-wide pgweb instance, and for how the pgweb host renders
# those advertisements into bookmark files.
#
# Consumers:
#   nix/modules/infra/data/postgresql/pgweb-access.nix   (every PG host)
#     - instanceSecretKey: the SOPS key holding this host's `pgweb`
#       role password.
#   nix/modules/infra/data/pgweb/default.nix             (the pgweb LXC)
#     - bookmarksOf: one bookmark TOML per database exported by a PG
#       node's `infra.data.postgresql.pgwebAccess`.
#
# Adding a database to any host that goes through these modules makes
# it appear in pgweb on the next deploy — no per-host wiring.
{ lib }:
rec {
  # One password per PG instance (not one fleet-wide) so a leaked
  # credential is scoped to a single server. Key derived from the
  # hostname on both ends; add the value with:
  #   fleet devtools secrets keys add dbs/pgweb/instances/<host> <pw>
  instanceSecretKey = hostName: "dbs/pgweb/instances/${hostName}";

  # Bookmark display name == file stem shown in the pgweb UI.
  bookmarkName = hostName: db: "${hostName}--${db}";

  # pgweb bookmark file (TOML, ~/.pgweb/bookmarks format). `password`
  # should be a sops-nix placeholder so credentials never enter the
  # Nix store.
  mkBookmarkToml = { ip, port, database, password, user ? "pgweb" }: ''
    host = "${ip}"
    port = ${toString port}
    user = "${user}"
    password = "${password}"
    database = "${database}"
    ssl = "disable"
  '';

  # All bookmarks advertised by one PG node.
  #   hostName    node name in the hive
  #   nodeCfg     that node's evaluated NixOS config
  #   mkPassword  hostName -> password string (placeholder on pgweb host)
  bookmarksOf = { hostName, nodeCfg, mkPassword }:
    let acc = nodeCfg.infra.data.postgresql.pgwebAccess;
    in map (db: {
      name = bookmarkName hostName db;
      content = mkBookmarkToml {
        ip = nodeCfg.infra.networking.internalIp;
        port = acc.port;
        database = db;
        password = mkPassword hostName;
      };
    }) (lib.unique acc.databases);
}
