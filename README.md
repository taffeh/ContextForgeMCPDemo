# Self-Hosted MCP Gateway on GCP Cloud Run

A repeatable setup for running a self-hosted MCP (Model Context Protocol) ecosystem on Google Cloud Platform, comprising:

1. **IBM ContextForge** — self-hosted MCP registry and gateway
2. **Vertex AI MCP Server** — custom MCP server exposing Google Gemini tools
3. **MCP Inspector** — browser-based test client for verifying the full chain

```
MCP Client (Inspector / Claude Desktop / Cursor)
        │
        ▼
ContextForge Gateway  (Cloud Run — europe-west2)
        │  aggregates tools from registered MCP servers
        ▼
Vertex AI MCP Server  (Cloud Run — europe-west2)
        │  uses workload identity
        ▼
Gemini 2.5 Flash  (Vertex AI — us-central1)
```

---

## Prerequisites

- A GCP project with billing enabled
- `gcloud` CLI authenticated (`gcloud auth login` + `gcloud auth application-default login`)
- Docker (only needed if you want to build locally — Cloud Build handles it in CI)
- `openssl` (used to generate secrets; installed by default on macOS/Linux)

---

## Repository structure

```
.
├── README.md
├── .env                        # local secrets — never commit this
├── .gitignore
├── deploy-contextforge.sh      # deploys IBM ContextForge to Cloud Run
└── mcp-server/
    ├── server.py               # FastMCP server wrapping Vertex AI / Gemini
    ├── requirements.txt
    ├── Dockerfile
    └── deploy.sh               # builds + deploys the MCP server to Cloud Run
```

---

## 1. Environment setup

Copy the example below to `.env` in the repo root and fill in your values.
**`.env` is in `.gitignore` — never commit it.**

```bash
# GCP project and region
GCP_PROJECT_ID="your-gcp-project-id"
GCP_REGION=europe-west2

# Vertex AI (Gemini) — model must be enabled in Vertex AI Model Garden
VERTEX_REGION=us-central1
VERTEX_MODEL=gemini-2.5-flash

# ContextForge admin credentials (set before first deploy)
CONTEXTFORGE_ADMIN_EMAIL=admin@example.com
CONTEXTFORGE_ADMIN_PASSWORD=ChangeMe2026!
CONTEXTFORGE_ADMIN_NAME=Demo Admin

# Optional — stable secrets across redeployments
# If unset, new random secrets are generated each deploy (breaks existing sessions)
# CONTEXTFORGE_JWT_SECRET=
# CONTEXTFORGE_ENCRYPTION_SECRET=
```

### Enable required GCP APIs

```bash
gcloud services enable \
  run.googleapis.com \
  containerregistry.googleapis.com \
  cloudbuild.googleapis.com \
  aiplatform.googleapis.com \
  secretmanager.googleapis.com \
  --project "$GCP_PROJECT_ID"
```

### Enable Gemini 2.5 Flash in Vertex AI Model Garden

Navigate to **Vertex AI → Model Garden** in the GCP console, search for `gemini-2.5-flash`, and click **Enable**. The model is only available in certain regions — `us-central1` is recommended.

---

## 2. Deploy the Vertex AI MCP Server

The MCP server is a small Python service that exposes four Gemini-powered tools over the MCP protocol. It uses **workload identity** — no API keys required.

### Service account

Create a service account and grant it Vertex AI access:

```bash
SA_NAME="vertex-mcp-sa"
SA_EMAIL="${SA_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create "$SA_NAME" \
  --display-name "Vertex AI MCP Server SA" \
  --project "$GCP_PROJECT_ID"

gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member "serviceAccount:${SA_EMAIL}" \
  --role "roles/aiplatform.user"
```

### Deploy

```bash
cd mcp-server
./deploy.sh
```

The script:
1. Submits a Cloud Build job to build and push the container image to GCR
2. Deploys to Cloud Run with the service account attached (workload identity)
3. Prints the service URL on completion

**Tools exposed by the server:**

| Tool | Description |
|---|---|
| `ask` | Send any prompt to Gemini and get a response |
| `summarize` | Summarise a block of text |
| `translate` | Translate text into a specified language |
| `extract_json` | Extract structured JSON from unstructured text |

The MCP endpoint is at: `https://<service-url>/sse`

---

## 3. Deploy IBM ContextForge

[IBM ContextForge](https://github.com/IBM/mcp-context-forge) is a self-hosted MCP registry and gateway. It lets you register upstream MCP servers and aggregate their tools into a single Virtual Server endpoint that any MCP client can connect to.

```bash
./deploy-contextforge.sh
```

The script:
1. Pulls `ghcr.io/ibm/mcp-context-forge:v1.0.5` via Cloud Build and pushes to GCR
   _(Cloud Run in europe-west2 cannot pull directly from GHCR)_
2. Deploys to Cloud Run with SQLite storage, 2 Gi RAM, 1 instance

> **Note on storage:** SQLite is ephemeral on Cloud Run — registrations are lost on cold start. For persistence, set `DATABASE_URL` to a Cloud SQL instance URL in `.env`.

On completion the script prints:

```
  Admin UI:      https://<service-url>/ui
  API docs:      https://<service-url>/docs
  Health check:  https://<service-url>/health
```

### First-time login

1. Open the Admin UI URL in your browser
2. Log in with the `CONTEXTFORGE_ADMIN_EMAIL` / `CONTEXTFORGE_ADMIN_PASSWORD` you set in `.env`

### Register the Vertex AI MCP Server

In the ContextForge UI:

1. Go to **MCP Servers → Add Server**
2. Fill in:
   - **Name:** `vertex-ai-tools`
   - **URL:** `https://<vertex-mcp-server-url>/sse`
   - **Transport:** SSE
   - **Auth:** None
3. Click **Test Connection** — ContextForge will discover the tools automatically
4. Save the server

### Create a Virtual Server

A Virtual Server is the aggregated endpoint that MCP clients connect to.

1. Go to **Virtual Servers → Create**
2. Give it a name (e.g. `demo`)
3. Add the `vertex-ai-tools` server you just registered
4. Save — copy the **Virtual Server UUID** from the detail page

Your MCP endpoint is:

```
https://<contextforge-url>/servers/<virtual-server-uuid>/mcp
```

---

## 4. Test with MCP Inspector

[MCP Inspector](https://github.com/modelcontextprotocol/inspector) is a browser-based tool for connecting to any MCP endpoint, browsing available tools, and running them interactively. It is the fastest way to verify that your full chain is working before wiring up a production client.

### Run MCP Inspector

No installation needed — run it with `npx`:

```bash
npx @modelcontextprotocol/inspector
```

This starts a local web server and opens the Inspector in your browser (default: `http://localhost:6274`).

### Connect to ContextForge

1. In the **Transport** dropdown, select **Streamable HTTP**
2. In the **URL** field, paste your ContextForge Virtual Server endpoint:
   ```
   https://<contextforge-url>/servers/<virtual-server-uuid>/mcp
   ```
3. Click **Connect**

The connection history panel should show:

```
1. initialize
2. logging/setLevel
3. tools/list
4. (ready)
```

### Browse and run tools

1. Click the **Tools** tab — all tools from your registered MCP servers appear here, prefixed with the server slug (e.g. `vertex-ai-tools-ask`)
2. Click a tool to expand it
3. Fill in the input fields and click **Run Tool**
4. The result appears in the right panel, validated against the output schema

**Example test — full chain verification:**

- Tool: `vertex-ai-tools-ask`
- Input: `prompt = "What is the capital of Wales?"`
- Expected result: `"The capital of Wales is **Cardiff**."`

A successful response confirms the entire chain is working:

```
MCP Inspector → ContextForge → Vertex AI MCP Server → Gemini 2.5 Flash
```

---

## Architecture notes

### Why ContextForge instead of a cloud-hosted MCP registry?

ContextForge is fully self-hosted — your tool registrations, API tokens, and traffic never leave your GCP project. It also supports aggregating tools from multiple upstream MCP servers into a single endpoint, which simplifies client configuration.

### Why SSE transport for the MCP server?

The Vertex AI MCP Server uses FastMCP's SSE transport (`/sse` endpoint). ContextForge's tool discovery issues a GET probe; SSE responds correctly to this. Streamable HTTP (`/mcp`) can return a `406 Not Acceptable` if the client omits the `Accept: text/event-stream` header, which some gateways do.

### Why `us-central1` for Vertex AI but `europe-west2` for Cloud Run?

Gemini 2.5 Flash is available in `us-central1` (and a small number of other regions) but not in `europe-west2`. Cloud Run services can call Vertex AI cross-region without issue; latency is acceptable for interactive tool use.

### Ephemeral SQLite on Cloud Run

Cloud Run containers have an ephemeral filesystem. SQLite data is lost when:
- The instance is replaced (new deployment)
- The instance scales to zero and back (if `--min-instances 0`)

The deploy script sets `--min-instances 1` to keep one instance warm. For production, replace the `DATABASE_URL` with a Cloud SQL (PostgreSQL) connection string.

---

## Connecting other MCP clients

Once ContextForge is running and a Virtual Server is configured, any MCP-compatible client can connect using the same endpoint.

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "contextforge": {
      "url": "https://<contextforge-url>/servers/<virtual-server-uuid>/mcp",
      "transport": "streamable-http"
    }
  }
}
```

Restart Claude Desktop. Your Gemini tools will appear in the tool picker.

### Cursor

Add to `.cursor/mcp.json` in your project (or the global Cursor MCP config):

```json
{
  "mcpServers": {
    "contextforge": {
      "url": "https://<contextforge-url>/servers/<virtual-server-uuid>/mcp",
      "transport": "streamable-http"
    }
  }
}
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| ContextForge login loops back to login page | Secure cookies rejected behind Cloud Run HTTPS proxy | Ensure `SECURE_COOKIES=false` is set |
| ContextForge OOM / 503 | Default 5 gunicorn workers exhausts RAM | Set `GUNICORN_WORKERS=2`, use `--memory 2Gi` |
| ContextForge tool discovery fails | Wrong endpoint URL or transport mismatch | Use `/sse` endpoint, SSE transport |
| `tools/call` returns "Server not found" | Wrong UUID format or using gateway ID not virtual server ID | Copy UUID from Virtual Server detail page, not MCP Server page |
| Vertex AI 404 | Model not available in the Cloud Run region | Set `VERTEX_REGION=us-central1`, enable model in Model Garden |
| Cloud Run can't pull GHCR image | GHCR not accessible from Cloud Run in europe-west2 | `deploy-contextforge.sh` handles this via Cloud Build mirror to GCR |
| Registrations lost after redeploy | SQLite is ephemeral | Add a Cloud SQL `DATABASE_URL` to `.env` for persistence |

---

## Resources

- [IBM ContextForge](https://github.com/IBM/mcp-context-forge)
- [FastMCP](https://github.com/jlowin/fastmcp)
- [MCP Inspector](https://github.com/modelcontextprotocol/inspector)
- [Model Context Protocol specification](https://spec.modelcontextprotocol.io)
- [Vertex AI Model Garden](https://console.cloud.google.com/vertex-ai/model-garden)
