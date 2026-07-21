#!/usr/bin/env bash
# deploy-contextforge.sh — Deploy IBM ContextForge MCP Gateway to Cloud Run
#
# Runs with SQLite (ephemeral — resets on cold start, fine for demo).
# For persistent storage, set DATABASE_URL to a Cloud SQL instance.
#
# Usage: ./deploy-contextforge.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a; source "${SCRIPT_DIR}/.env"; set +a
fi

# ── Config ────────────────────────────────────────────────────────────────────
GCP_PROJECT_ID="${GCP_PROJECT_ID:?Set GCP_PROJECT_ID in .env}"
GCP_REGION="${GCP_REGION:-europe-west2}"
SERVICE_NAME="contextforge-gateway"
UPSTREAM_IMAGE="ghcr.io/ibm/mcp-context-forge:v1.0.5"
IMAGE="gcr.io/${GCP_PROJECT_ID}/contextforge:latest"
PORT=4444

# Admin credentials — override in .env if desired
ADMIN_EMAIL="${CONTEXTFORGE_ADMIN_EMAIL:-admin@demo.local}"
ADMIN_PASSWORD="${CONTEXTFORGE_ADMIN_PASSWORD:-$(openssl rand -base64 16)}"
ADMIN_NAME="${CONTEXTFORGE_ADMIN_NAME:-Demo Admin}"

# Auto-generate secrets if not set
JWT_SECRET="${CONTEXTFORGE_JWT_SECRET:-$(openssl rand -base64 32)}"
ENCRYPTION_SECRET="${CONTEXTFORGE_ENCRYPTION_SECRET:-$(openssl rand -base64 32)}"

info() { echo "▶ $*"; }

info "Setting project to ${GCP_PROJECT_ID}"
gcloud config set project "${GCP_PROJECT_ID}" --quiet

info "Enabling required APIs"
gcloud services enable run.googleapis.com containerregistry.googleapis.com cloudbuild.googleapis.com \
  --project "${GCP_PROJECT_ID}"

info "Copying image from GHCR into GCR (Cloud Run can't pull from GHCR directly)"
CLOUDBUILD_TMP="${SCRIPT_DIR}/.cloudbuild-contextforge.yaml"
cat > "${CLOUDBUILD_TMP}" <<YAML
steps:
- name: 'gcr.io/cloud-builders/docker'
  args: ['pull', '${UPSTREAM_IMAGE}']
- name: 'gcr.io/cloud-builders/docker'
  args: ['tag', '${UPSTREAM_IMAGE}', '${IMAGE}']
images: ['${IMAGE}']
YAML
gcloud builds submit --no-source --project "${GCP_PROJECT_ID}" --config "${CLOUDBUILD_TMP}"
rm -f "${CLOUDBUILD_TMP}"

info "Deploying ${SERVICE_NAME} to Cloud Run in ${GCP_REGION}"
gcloud run deploy "${SERVICE_NAME}" \
  --image "${IMAGE}" \
  --platform managed \
  --region "${GCP_REGION}" \
  --port "${PORT}" \
  --allow-unauthenticated \
  --min-instances 1 \
  --max-instances 3 \
  --memory 2Gi \
  --cpu 1 \
  --timeout 120 \
  --concurrency 40 \
  --set-env-vars "\
HOST=0.0.0.0,\
DATABASE_URL=sqlite:///./mcp.db,\
JWT_SECRET_KEY=${JWT_SECRET},\
AUTH_ENCRYPTION_SECRET=${ENCRYPTION_SECRET},\
PLATFORM_ADMIN_EMAIL=${ADMIN_EMAIL},\
PLATFORM_ADMIN_PASSWORD=${ADMIN_PASSWORD},\
PLATFORM_ADMIN_FULL_NAME=${ADMIN_NAME},\
MCPGATEWAY_UI_ENABLED=true,\
MCPGATEWAY_ADMIN_API_ENABLED=true,\
SSRF_ENABLED=false,\
GUNICORN_WORKERS=2,\
SECURE_COOKIES=false" \
  --project "${GCP_PROJECT_ID}"

SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" \
  --platform managed \
  --region "${GCP_REGION}" \
  --format "value(status.address.url)" \
  --project "${GCP_PROJECT_ID}")

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ContextForge MCP Gateway deployed!"
echo ""
echo "  Admin UI:      ${SERVICE_URL}/ui"
echo "  API docs:      ${SERVICE_URL}/docs"
echo "  Health check:  ${SERVICE_URL}/health"
echo ""
echo "  Admin credentials:"
echo "    Email:    ${ADMIN_EMAIL}"
echo "    Password: ${ADMIN_PASSWORD}"
echo ""
echo "  MCP endpoint (after registering a server):"
echo "  ${SERVICE_URL}/mcp"
echo ""
echo "  ⚠  SQLite storage resets on cold start — add a Cloud SQL"
echo "     DATABASE_URL to .env for persistence."
echo ""
echo "  Compare with Portkey gateway:"
echo "  https://portkey-gateway-269318585453.europe-west2.run.app"
echo "════════════════════════════════════════════════════════════"
