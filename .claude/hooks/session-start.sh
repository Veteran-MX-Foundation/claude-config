#!/bin/bash
# Thin wrapper — delegates to the org-level Claude config repo.
# Full hook logic lives at:
# https://github.com/Veteran-MX-Foundation/claude-config/blob/main/hooks/session-start.sh

set -euo pipefail

STDIN=$(cat)
SCRIPT_URL="https://raw.githubusercontent.com/Veteran-MX-Foundation/claude-config/main/hooks/session-start.sh"

SCRIPT=$(curl -fsSL "$SCRIPT_URL" 2>/dev/null || echo "")

if [ -n "$SCRIPT" ]; then
  echo "$STDIN" | bash <(echo "$SCRIPT")
else
  echo "[session-hook] Could not fetch org hook from claude-config — skipping" >&2
fi
