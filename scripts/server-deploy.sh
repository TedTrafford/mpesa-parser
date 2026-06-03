#!/usr/bin/env bash
# scripts/server-deploy.sh
# ---------------------------------------------------------------------------
# Server-side deploy script -- called by the GitHub Actions deploy workflow
# whenever a commit lands on main.
#
# Assumptions:
#   - The repo is cloned at /var/www/server/parser (parse_single.py is at
#     /var/www/server/parser/parse_single.py).
#   - A virtualenv at /var/www/server/parser/.venv is created automatically if
#     missing (requires python3-venv on Ubuntu).
#   - The .env file with real credentials lives at /var/www/server/parser/.env
#     and is NOT tracked by git.
# ---------------------------------------------------------------------------

set -euo pipefail

DEPLOY_PATH="/var/www/server/parser"

echo ""
echo "=================================================="
echo "  Deploy started -- $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  Path: $DEPLOY_PATH"
echo "=================================================="

cd "$DEPLOY_PATH"

# -- 1. Pull latest code from main -------------------------------------------
echo ""
echo "[1/4] Pulling latest code..."
git fetch --prune origin
git checkout main
git reset --hard origin/main
echo "  HEAD is now at: $(git rev-parse --short HEAD) -- $(git log -1 --pretty=%s)"

# -- 2. Ensure virtualenv exists and sync dependencies -----------------------
echo ""
echo "[2/4] Syncing Python dependencies..."

if [ -f "$DEPLOY_PATH/.venv/bin/activate" ]; then
    VENV_ACTIVATE="$DEPLOY_PATH/.venv/bin/activate"
elif [ -f "$DEPLOY_PATH/venv/bin/activate" ]; then
    VENV_ACTIVATE="$DEPLOY_PATH/venv/bin/activate"
else
    echo "  No virtualenv found — creating $DEPLOY_PATH/.venv ..."
    if ! python3 -m venv "$DEPLOY_PATH/.venv"; then
        echo "  ERROR: could not create virtualenv."
        echo "  On Ubuntu install the venv module: apt install -y python3-venv python3-pip"
        exit 1
    fi
    VENV_ACTIVATE="$DEPLOY_PATH/.venv/bin/activate"
fi

# shellcheck source=/dev/null
source "$VENV_ACTIVATE"
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt
echo "  Dependencies up to date."

# -- 3. Apply pending database migrations ------------------------------------
# config.py auto-loads .env, but we also export it here as a safety net so the
# migration step provably targets the same database as the parser worker.
echo ""
echo "[3/4] Applying database migrations..."
if [ -f "$DEPLOY_PATH/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$DEPLOY_PATH/.env"
    set +a
    echo "  Loaded DB config from .env (host: ${MPESA_DB_HOST:-unset})"
else
    echo "  WARNING: no .env found at $DEPLOY_PATH/.env — migrations may target the wrong DB."
fi
python db/migrate.py
echo "  Migrations up to date."

# -- 4. Optional: restart a long-running systemd service ---------------------
# Uncomment if you run parse_single.py as a persistent service named "mpesa-parser":
#
# echo ""
# echo "[4/4] Restarting service..."
# sudo systemctl restart mpesa-parser
# sudo systemctl status  mpesa-parser --no-pager

echo ""
echo "[4/4] No persistent service to restart (on-demand processing model)."

echo ""
echo "=================================================="
echo "  Deploy complete -- $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "=================================================="
