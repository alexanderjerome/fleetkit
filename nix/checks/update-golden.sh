#!/usr/bin/env bash
# Regenerate nix/checks/golden/compute-surface/*.json from the fixture
# fleet. Run after an INTENDED change to the emitters/schema, review the
# diff, commit the goldens with the change. (`git add` the files — the
# golden check reads them from the flake source tree.)
#
#   nix/checks/update-golden.sh [extra nix args…]
set -euo pipefail
cd "$(dirname "$0")/../.."
out=nix/checks/golden/compute-surface
mkdir -p "$out"
slugs=$(nix eval --raw .#checks.x86_64-linux.compute-surface-golden.slugs "$@")
for slug in $slugs; do
  render=$(nix build --no-link --print-out-paths ".#checks.x86_64-linux.compute-surface-golden.renders.$slug" "$@")
  jq -S . "$render" > "$out/$slug.json"
  echo "wrote $out/$slug.json"
done
