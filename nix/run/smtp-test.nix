# nix/run/smtp-test.nix — Send a test email via Resend SMTP.
#
# Usage:
#   nix run .#smtp-test -- recipient@example.com
#   nix run .#smtp-test -- recipient@example.com "Custom subject"
#
# Reads SMTP credentials from SOPS (services/resend/*).
{ pkgs, lib, nixosConfigurations }:
let
  # Sender defaults derive from the fleet's public base domain; override
  # the address with SMTP_TEST_FROM if your relay validates a different
  # sender domain.
  baseDomain =
    if nixosConfigurations == {} then "example.com"
    else (lib.head (lib.attrValues nixosConfigurations)).config.fleet.settings.domain.base;

  script = pkgs.writeShellScriptBin "smtp-test" ''
    set -euo pipefail

    RECIPIENT="''${1:-}"
    SUBJECT="''${2:-Fleet SMTP Test}"

    if [ -z "$RECIPIENT" ]; then
      echo "Usage: nix run .#smtp-test -- recipient@example.com [subject]"
      exit 1
    fi

    ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
    SOPS_FILE="$ROOT/nix/secrets/secrets.yaml"

    # Source SOPS age key
    if [ -z "''${SOPS_AGE_KEY:-}" ] && [ -f "$ROOT/.ssh/sops-age.key" ]; then
      export SOPS_AGE_KEY="$(cat "$ROOT/.ssh/sops-age.key")"
    fi

    echo "Reading SMTP credentials from SOPS..."
    SMTP_HOST=$(${pkgs.sops}/bin/sops -d --extract '["services"]["resend"]["smtp_host"]' "$SOPS_FILE")
    SMTP_PORT=$(${pkgs.sops}/bin/sops -d --extract '["services"]["resend"]["smtp_port"]' "$SOPS_FILE")
    SMTP_USER=$(${pkgs.sops}/bin/sops -d --extract '["services"]["resend"]["smtp_username"]' "$SOPS_FILE")
    SMTP_PASS=$(${pkgs.sops}/bin/sops -d --extract '["services"]["resend"]["smtp_secret"]' "$SOPS_FILE")

    FROM="''${SMTP_TEST_FROM:-test@${baseDomain}}"
    TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

    echo "Sending test email..."
    echo "  From:    $FROM"
    echo "  To:      $RECIPIENT"
    echo "  Subject: $SUBJECT"
    echo "  Via:     $SMTP_HOST:$SMTP_PORT"
    echo ""

    ${pkgs.msmtp}/bin/msmtp \
      --host="$SMTP_HOST" \
      --port="$SMTP_PORT" \
      --auth=on \
      --user="$SMTP_USER" \
      --passwordeval="echo $SMTP_PASS" \
      --tls=on \
      --tls-starttls=on \
      --from="$FROM" \
      "$RECIPIENT" <<EOF
From: Fleet SMTP Test <$FROM>
To: $RECIPIENT
Subject: $SUBJECT
Content-Type: text/plain; charset=utf-8
Date: $TIMESTAMP

This is a test email from the fleet infrastructure.

Sent at: $TIMESTAMP
SMTP relay: $SMTP_HOST:$SMTP_PORT
Source: nix run .#smtp-test

If you received this, Resend SMTP is working correctly.
EOF

    echo ""
    echo "Done! Check $RECIPIENT inbox."
  '';
in
{
  smtp-test = script;
}
