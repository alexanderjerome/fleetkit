# nix/tf

Terranix emitters — translate the fleet manifest (`nix/fleet/`) into
Terraform JSON that OpenTofu applies. This is the provisioning half of
the pipeline; never run `tofu` directly, use `sk deploy tf <cmd>`.

`default.nix` is instantiated once per leaf stack
(`<env>.<stack>`, e.g. `dev.bitcoin.signet`) and configures the S3 state
backend (`s3://<your-tfstate-bucket>`, one tfstate per leaf). It imports:

- `providers/` — provider configs (Proxmox, Xen Orchestra, Cloudflare,
  PBS, Docker, SOPS) with credentials resolved from SOPS.
- `compute/` — emit containers/VMs from `fleet.compute` entries matching
  the stack (Proxmox LXC, XOA VM, ansible glue).
- `resources/` — emit non-compute resources (networks, pools, DNS
  records) from `fleet.resources`.

Emitters filter fleet entries by `stackId` passed through module args,
and refuse to emit unless `fleet._meta.validated` passes.
