#!/usr/bin/env bash
# scripts/setup-github-deploy-key.sh
# ---------------------------------------------------------------------------
# Generate an SSH key pair for GitHub Actions deploys and print the steps to
# install the public key on production (65.20.86.247) and store the private
# key in repository secrets.
#
# Usage (on your laptop):
#   bash scripts/setup-github-deploy-key.sh
#   bash scripts/setup-github-deploy-key.sh deploy   # key for user "deploy"
# ---------------------------------------------------------------------------

set -euo pipefail

SSH_USER="${1:-root}"
KEY_PATH="${2:-./gh_actions_deploy_key}"
PROD_HOST="65.20.86.247"

if [[ -f "${KEY_PATH}" || -f "${KEY_PATH}.pub" ]]; then
  echo "ERROR: ${KEY_PATH} or ${KEY_PATH}.pub already exists."
  echo "Remove them first or pass a different path as the second argument."
  exit 1
fi

echo "Generating Ed25519 deploy key (no passphrase)..."
ssh-keygen -t ed25519 -C "github-actions-aleza-deploy" -f "${KEY_PATH}" -N ""

echo ""
echo "============================================================"
echo "  1. On the server (${PROD_HOST}), as user: ${SSH_USER}"
echo "============================================================"
echo ""
cat <<EOF
mkdir -p ~/.ssh
chmod 700 ~/.ssh
echo "$(cat "${KEY_PATH}.pub")" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
# Optional: restrict this key to running the deploy script only
# (append the line below instead of the plain pub key line above)
# command="bash /var/www/server/parser/scripts/server-deploy.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "${KEY_PATH}.pub")
EOF

echo ""
echo "Verify login from this machine:"
echo "  ssh -i ${KEY_PATH} ${SSH_USER}@${PROD_HOST}"
echo ""
echo "============================================================"
echo "  2. GitHub repository secrets"
echo "     Settings ? Secrets and variables ? Actions"
echo "============================================================"
echo ""
echo "  SSH_USER         = ${SSH_USER}"
echo "  SSH_PRIVATE_KEY  = paste the ENTIRE file below (including BEGIN/END):"
echo ""
cat "${KEY_PATH}"
echo ""
echo "============================================================"
echo "  3. Re-run the Deploy workflow on main"
echo "============================================================"
echo ""
echo "Private key file: ${KEY_PATH}"
echo "Public key file:  ${KEY_PATH}.pub"
echo ""
echo "Keep ${KEY_PATH} secure. Do not commit it to git."
