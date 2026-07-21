#!/usr/bin/env bash
# gateway-mcp.sh — Create a ContextForge Virtual Server (the MCP endpoint clients connect to)
#
# A Virtual Server aggregates tools from one or more registered MCP servers
# into a single endpoint. This is what you point MCP clients at.
#
# Usage:
#   ./gateway-mcp.sh --gateway-id <id> --name "My Gateway"
#   ./gateway-mcp.sh            # interactive — lists registered servers to choose from

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a; source "${SCRIPT_DIR}/.env"; set +a
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { echo "▶ $*"; }
ok()    { echo "✔ $*"; }
err()   { echo "✖ $*" >&2; exit 1; }
line()  { echo "────────────────────────────────────────────────────────────"; }

# ── Dependency check ──────────────────────────────────────────────────────────
python3 -c "import jwt" 2>/dev/null || err "PyJWT not installed. Run: pip3 install PyJWT"

# ── Args ──────────────────────────────────────────────────────────────────────
GATEWAY_ID=""
VIRTUAL_SERVER_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gateway-id) GATEWAY_ID="$2";          shift 2 ;;
    --name)       VIRTUAL_SERVER_NAME="$2"; shift 2 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

# ── Resolve ContextForge URL ──────────────────────────────────────────────────
if [[ -z "${CONTEXTFORGE_URL:-}" ]]; then
  info "CONTEXTFORGE_URL not set — looking up Cloud Run service..."
  CONTEXTFORGE_URL=$(gcloud run services describe contextforge-gateway \
    --platform managed \
    --region "${GCP_REGION:-europe-west2}" \
    --project "${GCP_PROJECT_ID:?Set GCP_PROJECT_ID in .env}" \
    --format "value(status.address.url)") || err "Could not find contextforge-gateway on Cloud Run"
fi
BASE="${CONTEXTFORGE_URL%/}"

# ── Resolve JWT secret ────────────────────────────────────────────────────────
if [[ -z "${CONTEXTFORGE_JWT_SECRET:-}" ]]; then
  info "CONTEXTFORGE_JWT_SECRET not set — fetching from Cloud Run env vars..."
  CONTEXTFORGE_JWT_SECRET=$(gcloud run services describe contextforge-gateway \
    --platform managed \
    --region "${GCP_REGION:-europe-west2}" \
    --project "${GCP_PROJECT_ID}" \
    --format "json" | python3 -c "
import sys,json
envs=json.load(sys.stdin)['spec']['template']['spec']['containers'][0]['env']
print(next(e['value'] for e in envs if e['name']=='JWT_SECRET_KEY'))
") || err "Could not retrieve JWT secret from Cloud Run"
fi

# ── Generate bearer token ─────────────────────────────────────────────────────
TOKEN=$(python3 - <<PYEOF
import jwt, datetime, uuid
now = datetime.datetime.now(datetime.timezone.utc)
payload = {
    "sub":  "${CONTEXTFORGE_ADMIN_EMAIL:-admin@demo.local}",
    "iss":  "mcpgateway",
    "aud":  "mcpgateway-api",
    "jti":  str(uuid.uuid4()),
    "iat":  now,
    "exp":  now + datetime.timedelta(hours=1),
    "user": {
        "email":         "${CONTEXTFORGE_ADMIN_EMAIL:-admin@demo.local}",
        "is_admin":      True,
        "full_name":     "${CONTEXTFORGE_ADMIN_NAME:-Admin}",
        "auth_provider": "local",
    },
}
print(jwt.encode(payload, "${CONTEXTFORGE_JWT_SECRET}", algorithm="HS256"))
PYEOF
)

# ── Fetch registered MCP servers ──────────────────────────────────────────────
GATEWAYS_JSON=$(curl -s -H "Authorization: Bearer ${TOKEN}" "${BASE}/gateways")
GATEWAY_COUNT=$(echo "$GATEWAYS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

if [[ "$GATEWAY_COUNT" == "0" ]]; then
  err "No MCP servers registered yet. Run ./register-mcp.sh first."
fi

# ── Interactive server selection if no --gateway-id ───────────────────────────
if [[ -z "$GATEWAY_ID" ]]; then
  line
  echo ""
  echo "  Registered MCP servers:"
  echo ""
  echo "$GATEWAYS_JSON" | python3 -c "
import sys,json
gateways=json.load(sys.stdin)
for i,g in enumerate(gateways):
    status = '✔ enabled' if g.get('enabled') else '✖ disabled'
    print(f'  [{i+1}] {g[\"name\"]:35} {status}')
    print(f'      ID: {g[\"id\"]}')
    print()
"
  echo "  Enter the number(s) to include (comma-separated, or 'all'):"
  read -rp "  > " SELECTION

  if [[ "$SELECTION" == "all" ]]; then
    GATEWAY_IDS=$(echo "$GATEWAYS_JSON" | python3 -c "
import sys,json
gateways=json.load(sys.stdin)
print(' '.join(g['id'] for g in gateways))")
  else
    GATEWAY_IDS=$(echo "$GATEWAYS_JSON" | python3 -c "
import sys,json
gateways=json.load(sys.stdin)
indices=[int(x.strip())-1 for x in '${SELECTION}'.split(',')]
print(' '.join(gateways[i]['id'] for i in indices))")
  fi
else
  GATEWAY_IDS="$GATEWAY_ID"
fi

# ── Resolve virtual server name ───────────────────────────────────────────────
if [[ -z "$VIRTUAL_SERVER_NAME" ]]; then
  echo ""
  read -rp "  Virtual server name (e.g. 'demo'): " VIRTUAL_SERVER_NAME
fi
if [[ -z "$VIRTUAL_SERVER_NAME" ]]; then
  err "--name is required"
fi

# ── Collect tool IDs for selected gateways ────────────────────────────────────
ALL_TOOLS_JSON=$(curl -s -H "Authorization: Bearer ${TOKEN}" "${BASE}/tools")

TOOL_IDS_JSON=$(python3 - <<PYEOF
import json

all_tools = json.loads("""${ALL_TOOLS_JSON}""")
gateway_ids = "${GATEWAY_IDS}".split()

# Filter: include tools whose name starts with any gateway slug
# Also include tools by checking against all gateways if no filter needed
# When all gateways selected, include everything
if len(gateway_ids) >= int("${GATEWAY_COUNT}"):
    ids = [t["id"] for t in all_tools]
else:
    # Look up gateway names to build name-prefix filter
    gateways = json.loads("""${GATEWAYS_JSON}""")
    selected = {g["id"]: g["name"] for g in gateways if g["id"] in gateway_ids}
    # ContextForge prefixes tool names with a slug derived from the gateway name
    slugs = [name.lower().replace(" ", "-") for name in selected.values()]
    ids = [t["id"] for t in all_tools if any(t["name"].startswith(s) for s in slugs)]

print(json.dumps(ids))
PYEOF
)

TOOL_COUNT=$(echo "$TOOL_IDS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

if [[ "$TOOL_COUNT" == "0" ]]; then
  err "No tools found for the selected server(s). Check the server is enabled and connected."
fi

# ── Create the Virtual Server ─────────────────────────────────────────────────
line
echo ""
info "Creating Virtual Server '${VIRTUAL_SERVER_NAME}' with ${TOOL_COUNT} tool(s)..."
echo ""

PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'name': '${VIRTUAL_SERVER_NAME}',
  'description': 'Created by gateway-mcp.sh',
  'associatedToolIds': ${TOOL_IDS_JSON},
}))
")

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${BASE}/servers" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
  echo "Response: $BODY"
  err "Virtual server creation failed (HTTP ${HTTP_CODE})"
fi

VS_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
MCP_ENDPOINT="${BASE}/servers/${VS_ID}/mcp"

# ── Show tools included ───────────────────────────────────────────────────────
ok "Virtual Server created!"
echo ""
info "Tools included:"
echo "$ALL_TOOLS_JSON" | python3 -c "
import sys,json
ids=set(${TOOL_IDS_JSON})
tools=json.load(sys.stdin)
for t in tools:
    if t['id'] in ids:
        print(f'  • {t[\"name\"]:40} {t.get(\"description\",\"\")[:55]}')
"

echo ""
line
echo ""
echo "  Virtual Server ID: ${VS_ID}"
echo ""
echo "  MCP endpoint:  ${MCP_ENDPOINT}"
echo ""
echo "  Connect with MCP Inspector:"
echo "    npx @modelcontextprotocol/inspector"
echo "    Transport: Streamable HTTP"
echo "    URL: ${MCP_ENDPOINT}"
echo ""
echo "  Claude Desktop / Cursor config:"
cat <<JSON
    {
      "mcpServers": {
        "${VIRTUAL_SERVER_NAME}": {
          "url": "${MCP_ENDPOINT}"
        }
      }
    }
JSON
echo ""
line
