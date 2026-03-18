#!/bin/bash
# SessionStart hook: auto-creates a Linear issue for new claude/ branches
# Requires LINEAR_API_KEY to be set in the environment

set -euo pipefail

# Only run in Claude Code on the web
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Require LINEAR_API_KEY
if [ -z "${LINEAR_API_KEY:-}" ]; then
  echo "[linear-hook] LINEAR_API_KEY not set — skipping issue creation" >&2
  exit 0
fi

# Read session JSON from stdin
SESSION_JSON=$(cat)
SESSION_ID=$(echo "$SESSION_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
SOURCE=$(echo "$SESSION_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('source',''))" 2>/dev/null || echo "")

# Only run on new sessions — skip resume, clear, compact
if [ "$SOURCE" != "startup" ]; then
  exit 0
fi

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
BRANCH=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "")

# Only act on claude/ branches
if [[ ! "$BRANCH" =~ ^claude/ ]]; then
  exit 0
fi

SESSION_URL="https://claude.ai/code/session_${SESSION_ID}"
BRANCH_MAP="$PROJECT_DIR/.claude/linear-branch-map.json"

# ── Deduplication: check if this branch already has an issue ────────────────
if [ -f "$BRANCH_MAP" ]; then
  EXISTING_URL=$(python3 - "$BRANCH" "$BRANCH_MAP" <<'PYEOF'
import sys, json
branch, map_file = sys.argv[1], sys.argv[2]
try:
  data = json.load(open(map_file))
  print(data.get(branch, {}).get("url", ""))
except Exception:
  print("")
PYEOF
  )
  if [ -n "$EXISTING_URL" ]; then
    echo "export LINEAR_ISSUE_URL=\"$EXISTING_URL\"" >> "${CLAUDE_ENV_FILE:-/dev/null}"
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ Linear issue already exists for this branch:                    │"
    echo "│ $EXISTING_URL"
    echo "└─────────────────────────────────────────────────────────────────┘"
    exit 0
  fi
fi

# ── Infer title from branch name ─────────────────────────────────────────────
BRANCH_SLUG="${BRANCH#claude/}"
# Strip the trailing session-ID suffix (e.g. -Y0lDk or -01ShxL...)
CLEAN_SLUG=$(echo "$BRANCH_SLUG" | sed 's/-[A-Za-z0-9]\{4,\}$//')
TITLE=$(echo "$CLEAN_SLUG" | tr '-' ' ' | python3 -c "import sys; print(sys.stdin.read().strip().title())")

# ── Map branch keywords → Linear project ID ──────────────────────────────────
BRANCH_LOWER=$(echo "$BRANCH_SLUG" | tr '[:upper:]' '[:lower:]')
TEAM_ID="0279b31c-b0b7-4846-ac48-85e837762c45"  # Tech

# Default: Member App - Post-Deployment Work (catch-all for vetmx-web branches)
PROJECT_ID="ea02b53d-945a-4b16-9de1-75c3ac2c1247"

if echo "$BRANCH_LOWER" | grep -qE "notif"; then
  PROJECT_ID="72cb4c5f-3eb0-4046-9458-45e5fcc75f23"   # Member App - Notifications System
elif echo "$BRANCH_LOWER" | grep -qE "rbac|role|permission"; then
  PROJECT_ID="1e9f08ba-56b9-4427-b58a-0b8dd51b69b4"   # Member App — RBAC
elif echo "$BRANCH_LOWER" | grep -qE "deploy|infra|devops|pipeline"; then
  PROJECT_ID="1b27e371-99c6-40f2-98fa-d52e42986959"   # Infrastructure & DevOps
elif echo "$BRANCH_LOWER" | grep -qE "auth|login|token|password|signup|register"; then
  PROJECT_ID="de288d58-5224-42ea-ad7f-445ed1823ab7"   # Authentication & Access Control
elif echo "$BRANCH_LOWER" | grep -qE "payment|stripe|subscription|billing|checkout"; then
  PROJECT_ID="ec21827a-2a08-4c58-b3c0-b970336a1253"   # Payments & Membership (Stripe)
elif echo "$BRANCH_LOWER" | grep -qE "email|sms|communication|newsletter|engage"; then
  PROJECT_ID="814c266d-27dc-4340-8cad-58e52ad270f7"   # Communication & Member Engagement
elif echo "$BRANCH_LOWER" | grep -qE "monitor|logging|sentry|observ|alert|uptime"; then
  PROJECT_ID="e0b194f0-9d19-480a-a14b-0c637b9081de"   # Observability & Stack Integrations
elif echo "$BRANCH_LOWER" | grep -qE "mobile|native|expo|ios|android"; then
  PROJECT_ID="0b1ecc22-5d60-4b35-856d-f678d104395a"   # VetMX Mobile App
elif echo "$BRANCH_LOWER" | grep -qE "roadmap|feedback|featurebase"; then
  PROJECT_ID="214ff58e-53ef-4588-8ff0-94a5750b0b27"   # Roadmap and Feedback Portal
elif echo "$BRANCH_LOWER" | grep -qE "support"; then
  PROJECT_ID="f966b411-cd5a-4836-84f6-a23502d8dcc2"   # Support Portal
elif echo "$BRANCH_LOWER" | grep -qE "wix|paypal"; then
  PROJECT_ID="b18c0527-9a33-4d1e-999a-680c15285783"   # Membership Migration — Wix/PayPal → Stripe
elif echo "$BRANCH_LOWER" | grep -qE "domain|dns|cloudflare|godaddy"; then
  PROJECT_ID="ce66def2-e8ad-4f85-a16c-495d1f98be3a"   # Domain Migration
elif echo "$BRANCH_LOWER" | grep -qE "workspace|microsoft|office365|google.workspace"; then
  PROJECT_ID="82a0774f-1ba8-4d9c-bd00-1efccd194fc6"   # Workspace Migration
fi

# ── Build the GraphQL mutation payload via Python (avoids bash escaping) ──────
DESCRIPTION="## Claude Code Session\n\n${SESSION_URL}\n\n## Branch\n\n\`${BRANCH}\` → [view on GitHub](https://github.com/Veteran-MX-Foundation/vetmx-web/tree/${BRANCH})"

PAYLOAD=$(python3 - "$TITLE" "$TEAM_ID" "$PROJECT_ID" "$DESCRIPTION" <<'PYEOF'
import sys, json
title, team_id, project_id, description = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
payload = {
  "query": """mutation CreateIssue($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      issue { id identifier title url }
    }
  }""",
  "variables": {
    "input": {
      "title": title,
      "teamId": team_id,
      "projectId": project_id,
      "description": description,
      "priority": 3
    }
  }
}
print(json.dumps(payload))
PYEOF
)

# ── Call Linear API ───────────────────────────────────────────────────────────
RESPONSE=$(curl -s -X POST \
  -H "Authorization: ${LINEAR_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "https://api.linear.app/graphql" 2>/dev/null || echo "{}")

ISSUE_URL=$(python3 -c "
import sys, json
try:
  print(json.loads('''$RESPONSE''')['data']['issueCreate']['issue']['url'])
except Exception:
  print('')
" 2>/dev/null || echo "")

ISSUE_ID=$(python3 -c "
import sys, json
try:
  print(json.loads('''$RESPONSE''')['data']['issueCreate']['issue']['identifier'])
except Exception:
  print('')
" 2>/dev/null || echo "")

# ── Persist branch → issue mapping ───────────────────────────────────────────
if [ -n "$ISSUE_URL" ]; then
  python3 - "$BRANCH" "$ISSUE_URL" "$ISSUE_ID" "$BRANCH_MAP" <<'PYEOF'
import sys, json, os
branch, url, identifier, map_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = {}
if os.path.exists(map_file):
  try:
    data = json.load(open(map_file))
  except Exception:
    data = {}
data[branch] = {"url": url, "id": identifier}
json.dump(data, open(map_file, "w"), indent=2)
PYEOF

  echo "export LINEAR_ISSUE_URL=\"$ISSUE_URL\"" >> "${CLAUDE_ENV_FILE:-/dev/null}"

  echo ""
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ Linear issue created: ${ISSUE_ID}"
  echo "│ ${ISSUE_URL}"
  echo "│ Branch: ${BRANCH}"
  echo "└─────────────────────────────────────────────────────────────────┘"
else
  echo "[linear-hook] Failed to create Linear issue. Response: $RESPONSE" >&2
fi
