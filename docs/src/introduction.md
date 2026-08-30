# fleetkit

A parameterized NixOS fleet framework: fleet manifest schema, terranix
emitters (Proxmox VE, Xen Orchestra, Cloudflare, Grafana), colmena
integration via `lib.mkFleet`, an operator CLI (`fleet`), and a generic
infra module tree.

Every site-specific value lives behind the options documented here —
`fleet.*` (the manifest schema: compute, network, settings) and
`infra.*` (the NixOS service modules). Nothing is baked in.

Start from the template:

```console
$ nix flake init -t github:alexanderjerome/fleetkit
$ fleet secrets init
```

The [Options Reference](./options.md) is generated from the module
declarations on every build — it cannot drift from the code.
