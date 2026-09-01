{
  # fleetkit — reusable fleet provisioning + deployment framework
  # (ADR-092 / INFRA-218, extracted from a production fleet deployment repo).
  #
  # The framework owns MACHINERY: the fleet manifest schema, terranix
  # emitters (Proxmox / Xen Orchestra / DNS), the Colmena/NixOS host
  # assembly, generic NixOS modules, bootstrap images, and the `fleet`
  # operator CLI. It owns NO environment data: hosts, providers,
  # networks, identities, DNS zones, secrets, and app flakes all live
  # in a CONSUMER repo, which calls `fleetkit.lib.mkFleet` with its
  # manifest modules and re-exports the result as its own flake
  # outputs. See templates/minimal for the consumer skeleton.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Terranix emits Terraform JSON from Nix modules.
    terranix = {
      url = "github:terranix/terranix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Build-time disk formatter for the bootstrap images (never re-runs
    # at activation, so it can't wipe live machines on rebuild).
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Automated topology diagrams (SVG) rendered from the fleet manifest.
    nix-topology = {
      url = "github:oddlama/nix-topology";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, terranix, sops-nix, disko, nix-topology }:
  let
    nixLib = import ./nix/lib { inherit nixpkgs; };

    # ── The framework entry point ─────────────────────────────────
    #
    # fleetkit.lib.mkFleet {
    #   modules            = [ ./fleet ];        # manifest data: hosts, providers,
    #                                            # network, users, dns, fleet.settings
    #   backend            = { bucket = "my-tofu-state"; };   # tofu state (S3)
    #   globalModules      = [ ... ];            # NixOS modules for every host
    #                                            # (app flakes, _module.args, ...)
    #   hostExtraModules   = { host = [ ... ]; };# flake-input modules for one host
    #   colmenaOverlays    = [ ... ];            # nixpkgs overlays for colmena meta
    #   system             = "x86_64-linux";
    #   sopsAgeKeyCommand  = [ ... ];            # colmena sops key lookup
    # }
    # → { fleetEval, hosts, deployable, colmena, nixosConfigurations,
    #     packages (hostsJson / tf-stack-ids / tf-<slug>… / run utils),
    #     fleetManifest, fleetAccess }
    #
    # The consumer re-exports these as its own flake outputs, so
    # `colmena`, `nix build .#tf-<slug>`, and the fleet CLI's
    # contracts all keep working unchanged.
    mkFleet = {
      modules,
      backend,
      globalModules ? [],
      hostExtraModules ? {},
      colmenaOverlays ? [],
      system ? "x86_64-linux",
      sopsAgeKeyCommand ? [ "sh" "-c" "cat \"$HOME/.ssh/sops-age.key\"" ],
      # Path to the consumer's SOPS store (scaffold it with `fleet
      # secrets init`). Wired into sops.defaultSopsFile on every host so
      # modules' sopsLib.mkSecret declarations resolve without any
      # per-consumer sops plumbing. null = consumer wires sops itself
      # (or runs a fleet with no secrets — most modules won't).
      secretsFile ? null,
    }:
    let
      pkgs = import nixpkgs { inherit system; };

      # Single fleet eval — the source of truth for every host's
      # vm_id / ip / internal_ip / tags / kind and the leaf stacks.
      # fleetLib is injected into the MANIFEST eval too, not just into NixOS
      # hosts: consumer manifest modules (Grafana Cloud checks, PVE notes)
      # need the same builders at fleet-eval time, where no NixOS module
      # argument exists yet.
      fleetLib = import ./nix/lib/module-args.nix { lib = nixpkgs.lib; inherit pkgs; };

      fleetEval = (nixpkgs.lib.evalModules {
        modules = [ ./nix/fleet { _module.args.fleetLib = fleetLib; } ] ++ modules;
      }).config.fleet;

      hosts =
        let
          base = nixLib.mkHosts {
            hosts    = fleetEval.hostsRegistry;
            runtime  = fleetEval.hostsJson;
            helpers  = {
              dnsRecords       = fleetEval.dnsRecords;
              publicDnsRecords = fleetEval.publicDnsRecords;
            };
          };
        in
        nixpkgs.lib.mapAttrs
          (name: h: h // { modules = h.modules ++ (hostExtraModules.${name} or []); })
          base;

      deployable = nixpkgs.lib.filterAttrs (_: h: h ? targetHost) hosts;

      # NixOS modules every host gets: the framework's generic modules,
      # the fleet schema + the consumer's manifest data (so any module
      # can read config.fleet.hostsJson / .network / .settings), sops,
      # and whatever the consumer passes.
      baseGlobalModules = [
        sops-nix.nixosModules.sops
        disko.nixosModules.disko
        ./nix/modules
        ./nix/fleet
        # fleetkit's public helper surface, so CONSUMER modules can reach the
        # same builders framework modules use (sops secret declaration, grafana
        # dashboards, PVE notes, …) without vendoring a copy or path-importing
        # into this flake's store path. See nix/lib/module-args.nix.
        { _module.args.fleetLib = fleetLib; }
      ] ++ nixpkgs.lib.optional (secretsFile != null)
        { sops.defaultSopsFile = secretsFile; }
      ++ modules ++ globalModules;

      # One terranixConfiguration per leaf stack (env.stack dot-path).
      # Each emits its own config.tf.json and owns its own state key.
      mkTerranixStack = stackId: terranix.lib.terranixConfiguration {
        inherit system;
        modules = [ (import ./nix/tf {
          inherit stackId backend fleetLib;
          fleetModules = modules;
        }) ];
      };

      leafStackIds = nixpkgs.lib.attrNames fleetEval.stacks;
      slugOf = id: nixpkgs.lib.replaceStrings [ "." ] [ "-" ] id;

      nixosConfigurations = nixLib.mkNixosConfigurations {
        inherit hosts;
        globalModules = baseGlobalModules;
      };
    in
    {
      inherit fleetEval hosts deployable nixosConfigurations;
      # Exposed so a consumer can hand the same helper surface to code that is
      # neither a NixOS module nor a manifest module — flake-level `nix run`
      # utilities, for instance, which are plain imports with explicit args.
      inherit fleetLib;

      fleetManifest = fleetEval.compute;
      fleetAccess   = fleetEval.access;

      colmena = {
        meta.nixpkgs = import nixpkgs {
          localSystem = system;
          overlays = colmenaOverlays;
        };
      } // nixLib.mkColmenaNodes {
        hosts = deployable;
        globalModules = baseGlobalModules;
        inherit sopsAgeKeyCommand;
      };

      packages =
        {
          # Flat inventory for non-Nix consumers (the fleet CLI, JSON tools).
          hostsJson = pkgs.writeText "hosts.json"
            (builtins.toJSON fleetEval.hostsJson);

          # Authoritative leaf stack IDs — the fleet CLI reads this to
          # enumerate stacks without re-evaluating the fleet module.
          tf-stack-ids = pkgs.writeText "tf-stack-ids.json"
            (builtins.toJSON leafStackIds);

          # fleet.settings as JSON — read by eval-free CLI features that
          # need Nix-side settings (e.g. `fleet mcp config` deriving the
          # fleet's observability MCP endpoints). Settings hold no secret
          # VALUES (secrets are sops paths), so this is safe to build.
          settings-json = pkgs.writeText "fleet-settings.json"
            (builtins.toJSON fleetEval.settings);

        }
        # One `tf-<env>-<stack>` package per leaf stack:
        # `nix build .#tf-platform-core` → config.tf.json for tofu.
        // nixpkgs.lib.listToAttrs (map (id: {
          name = "tf-${slugOf id}";
          value = mkTerranixStack id;
        }) leafStackIds)
        # Fleet-walking utility commands (service catalog, topology, …).
        // (import ./nix/run {
          inherit pkgs nix-topology nixosConfigurations;
          lib = nixpkgs.lib;
          fleetCompute = fleetEval.compute;
        });
    };

  in
  (flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs { inherit system; };
    in {
      packages = rec {
        # The operator CLI (was `sk`; renamed in the extraction).
        fleet = pkgs.callPackage ./nix/pkgs/_launcher { };
        default = fleet;

        # pve-cli (wraps Corsinvest cv4pve) — kubectl-style remote CLI for Proxmox VE.
        pve-cli = pkgs.callPackage ./nix/pkgs/pve-cli { };

        # Options documentation site (mdBook + nixosOptionsDoc, generated
        # from the module declarations — cannot drift from the code).
        docs = import ./docs {
          inherit pkgs nixpkgs sops-nix disko;
        };

        # The same option data as structured JSON — the machine/agent-
        # preferred API surface (name, type, default, description,
        # declaring file per option).
        options-json = docs.passthru.optionsJSON;

        # xoa-cli — standalone Xen Orchestra operator CLI. Reads over XO
        # REST, mutations over the JSON-RPC websocket. Drives the
        # size_add_gb disk-grow reconciler.
        xoa-cli = pkgs.callPackage ./nix/pkgs/xoa-cli { };

        # Prometheus exporter for XCP-ng tiers via the XO REST API (for

        # Prepared Debian cloud image: firstboot fixes + docker/

      };

      # Two shells only (by design): `default` for local dev, `ci` for
      # non-interactive pipelines. Consumers build their own via lib.mkDevShell.
      devShells = {
        default = import ./nix/shell.nix { inherit pkgs; mode = "dev"; };
        ci      = import ./nix/shell.nix { inherit pkgs; mode = "ci"; };
      };
    }
  )) // {
    lib = {
      inherit mkFleet;
      # Consumer devshell: same toolchain as the framework shell, plus
      # the consumer's fleet (builder discovery) and extras.
      #   fleetkit.lib.mkDevShell { pkgs, fleet, extraPackages, extraShellHook, mode ? "dev" }
      mkDevShell = import ./nix/shell.nix;
      # Lower-level helpers for consumers with bespoke assembly needs.
      inherit (nixLib) mkHosts mkNixosConfigurations mkColmenaNodes;
    };

    # Generic NixOS modules + the fleet schema, importable piecemeal by
    # consumers that don't go through mkFleet.
    nixosModules = {
      default = ./nix/modules;
      fleetSchema = ./nix/fleet;
    };

    templates.minimal = {
      path = ./templates/minimal;
      description = "Minimal fleetkit consumer: one manifest module, one host, mkFleet wiring.";
    };

    # Standalone acceptance: mkFleet over the template's example
    # manifest must assemble a deployable host end-to-end (fleet eval →
    # hostsJson → full NixOS module stack). `nix eval
    # .#checks.x86_64-linux.example-fleet.drvPath` forces it without
    # building; `nix flake check` builds it.
    checks.x86_64-linux = import ./nix/checks.nix {
      inherit nixpkgs mkFleet sops-nix disko;
    };
  };
}
