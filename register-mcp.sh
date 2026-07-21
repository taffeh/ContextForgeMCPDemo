#!/usr/bin/env bash
# register-mcp.sh — Register an upstream MCP server with ContextForge
#
# Usage:
#   ./register-mcp.sh --name "Vertex AI Tools" --url "https://..." [--transport SSE]
#   ./register-mcp.sh            # interactive prompts

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
python3 -c "import json, uuid, datetime" 2>/dev/null || err "Python stdlib missing"

# ── Args / interactive prompts ────────────────────────────────────────────────
SERVER_NAME=""
SERVER_URL=""
TRANSPORT="SSE"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)      SERVER_NAME="$2"; shift 2 ;;
    --url)       SERVER_URL="$2";  shift 2 ;;
    --transport) TRANSPORT="$2";   shift 2 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

if [[ -z "$SERVER_NAME" ]]; then
  read -rp "Server name (e.g. 'Vertex AI Tools'): " SERVER_NAME
fi
if [[ -z "$SERVER_URL" ]]; then
  read -rp "Server URL (e.g. 'https://my-server.run.app/sse'): " SERVER_URL
fi
if [[ -z "$SERVER_NAME" || -z "$SERVER_URL" ]]; then
  err "Both --name and --url are required"
fi

# ── Resolve ContextForge URL ──────────────────────────────────────────────────
if [[ -z "${CONTEXTFORGE_URL:-}" ]]; then
  info "CONTEXTFORGE_URL not set in .env — looking up Cloud Run service..."
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

# ── Register the MCP server ───────────────────────────────────────────────────
line
info "Registering '${SERVER_NAME}' with ContextForge..."
info "  URL:       ${SERVER_URL}"
info "  Transport: ${TRANSPORT}"
echo ""

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${BASE}/gateways" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${SERVER_NAME}\", \"url\": \"${SERVER_URL}\", \"transport\": \"${TRANSPORT}\"}")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
  echo "Response: $BODY"
  err "Registration failed (HTTP ${HTTP_CODE})"
fi

GATEWAY_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

ok "Server registered!"
echo ""
echo "  Gateway ID: ${GATEWAY_ID}"
echo ""

# ── Show discovered tools ─────────────────────────────────────────────────────
info "Discovered tools:"
curl -s -H "Authorization: Bearer ${TOKEN}" "${BASE}/tools" | python3 -c "
import sys,json
tools = json.load(sys.stdin)
for t in tools:
    print(f'  • {t[\"name\"]:40} {t.get(\"description\",\"\")[:60]}')
"

echo ""
line
echo ""
echo "  Next step: create a gateway endpoint so clients can connect."
echo ""
echo "  Run:  ./gateway-mcp.sh --gateway-id ${GATEWAY_ID}"
echo ""
line
