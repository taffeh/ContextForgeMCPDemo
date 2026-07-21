# Self-Hosted MCP Gateway on GCP Cloud Run

A repeatable setup for running a self-hosted MCP (Model Context Protocol) ecosystem on Google Cloud Platform, comprising:

1. **IBM ContextForge** — self-hosted MCP registry and gateway
2. **Vertex AI MCP Server** — custom MCP server exposing Google Gemini tools
3. **`register-mcp.sh`** — script to register any MCP server with ContextForge via API
4. **`gateway-mcp.sh`** — script to create a client-facing Virtual Server endpoint
5. **MCP Inspector** — browser-based test client for verifying the full chain

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

## MCP concepts: client, registry, gateway, server, LLM

```
┌─────────────────────────────────────────────────────────────────┐
│                        MCP ECOSYSTEM                            │
│                                                                 │
│  ┌──────────────┐                                               │
│  │  MCP CLIENT  │  Claude Desktop, Cursor, MCP Inspector        │
│  │              │  "I need to call a tool"                      │
│  └──────┬───────┘                                               │
│         │ MCP protocol (Streamable HTTP / SSE)                  │
│         ▼                                                       │
│  ┌──────────────┐                                               │
│  │  MCP REGISTRY│  Catalogue of available MCP servers           │
│  │              │  "Here is what tools exist and where they are" │
│  └──────┬───────┘                                               │
│         │ routes call to correct server                         │
│         ▼                                                       │
│  ┌──────────────┐                                               │
│  │  MCP GATEWAY │  Proxies the MCP call to the upstream server  │
│  │              │  handles auth, aggregation, Virtual Servers    │
│  └──────┬───────┘                                               │
│         │ MCP protocol (SSE)                                    │
│         ▼                                                       │
│  ┌──────────────┐                                               │
│  │  MCP SERVER  │  Implements the actual tools                  │
│  │              │  "ask", "summarize", "translate", etc.        │
│  └──────┬───────┘                                               │
│         │ SDK / API call                                        │
│         ▼                                                       │
│  ┌──────────────┐                                               │
│  │     LLM      │  Does the inference                           │
│  │              │  Gemini, GPT-4, Claude, etc.                  │
│  └──────────────┘                                               │
└─────────────────────────────────────────────────────────────────┘
```

### How our stack maps to each role

| Role | What we used | Where it runs |
|---|---|---|
| MCP Client | MCP Inspector (browser), Claude Desktop, Cursor | Your laptop |
| MCP Registry | ContextForge UI — register servers, create Virtual Servers | Cloud Run (europe-west2) |
| MCP Gateway | ContextForge `/servers/{uuid}/mcp` — single endpoint for clients | Cloud Run (europe-west2) |
| MCP Server | Vertex AI MCP Server (`server.py` via FastMCP) | Cloud Run (europe-west2) |
| LLM | Gemini 2.5 Flash via workload identity (no API keys) | Vertex AI (us-central1) |

### Registry vs Gateway

In many systems these are separate concerns. ContextForge combines both:

```
ContextForge
├── Registry  →  UI where you register servers + create Virtual Servers
└── Gateway   →  /servers/{uuid}/mcp endpoint that clients actually call
```

The client only ever talks to the Gateway endpoint. It never needs to know about the underlying servers — that is the Registry's job.

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
├── .env.example                # copy this to .env and fill in your values
├── .gitignore
├── deploy-contextforge.sh      # deploys IBM ContextForge to Cloud Run
├── register-mcp.sh             # registers an upstream MCP server with ContextForge
├── gateway-mcp.sh              # creates a Virtual Server endpoint for MCP clients
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

# Optional — set to avoid a gcloud lookup on every script run
# CONTEXTFORGE_URL=https://contextforge-gateway-xxxxxxxxxx-xx.a.run.app

# Pin these so sessions and API tokens stay valid across redeployments
# Generate with: openssl rand -base64 32
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

> The UI is optional — the two scripts below handle all registration and gateway creation without it.

### Prerequisite: pin your JWT secret

The scripts generate API tokens using your ContextForge JWT secret. Add a stable value to `.env` before running them, otherwise a new random secret is generated on each deployment and existing tokens break:

```bash
# Add to .env
CONTEXTFORGE_JWT_SECRET=$(openssl rand -base64 32)
```

Then redeploy ContextForge once so it picks up the fixed secret:

```bash
./deploy-contextforge.sh
```

Also install PyJWT, which the scripts use to generate bearer tokens:

```bash
pip3 install PyJWT
```

---

## 4. Register an MCP server — `register-mcp.sh`

`register-mcp.sh` tells ContextForge about an upstream MCP server. It connects to the server, discovers all available tools automatically, and registers them in the ContextForge catalogue.

**With arguments:**

```bash
./register-mcp.sh \
  --name "Vertex AI Tools" \
  --url  "https://<vertex-mcp-server-url>/sse" \
  --transport SSE
```

**Interactive (prompts for name, URL, transport):**

```bash
./register-mcp.sh
```

**Example output:**

```
▶ Registering 'Vertex AI Tools' with ContextForge...

✔ Server registered!

  Gateway ID: 0f37497d47804e499bf8a7f2978b9766

▶ Discovered tools:
  • vertex-ai-tools-ask          Send a prompt to Gemini and return the response.
  • vertex-ai-tools-summarize    Summarize a piece of text using Gemini.
  • vertex-ai-tools-translate    Translate text into the specified language using Gemini.
  • vertex-ai-tools-extract-json Extract structured data from unstructured text as JSON.

  Next step: create a gateway endpoint so clients can connect.

  Run:  ./gateway-mcp.sh --gateway-id 0f37497d47804e499bf8a7f2978b9766
```

Copy the **Gateway ID** from the output — you will need it in the next step.

---

## 5. Create the client-facing gateway — `gateway-mcp.sh`

`gateway-mcp.sh` creates a **Virtual Server** in ContextForge: a single MCP endpoint that aggregates tools from one or more registered servers. This is the URL you give to MCP clients.

**With arguments (using the Gateway ID from the previous step):**

```bash
./gateway-mcp.sh \
  --gateway-id 0f37497d47804e499bf8a7f2978b9766 \
  --name "demo"
```

**Interactive (lists registered servers, prompts for selection):**

```bash
./gateway-mcp.sh
```

The interactive mode shows a numbered list of all registered servers so you can pick which ones to include — useful when you have multiple MCP servers and want to combine their tools into one endpoint.

**Example output:**

```
✔ Virtual Server created!

▶ Tools included:
  • vertex-ai-tools-ask          Send a prompt to Gemini and return the response.
  • vertex-ai-tools-summarize    Summarize a piece of text using Gemini.
  • vertex-ai-tools-translate    Translate text into the specified language using Gemini.
  • vertex-ai-tools-extract-json Extract structured data from unstructured text as JSON.

  Virtual Server ID: cff6090b9cd74c0682b08e6666d5f396

  MCP endpoint:  https://<contextforge-url>/servers/cff6090b9cd74c0682b08e6666d5f396/mcp

  Connect with MCP Inspector:
    npx @modelcontextprotocol/inspector
    Transport: Streamable HTTP
    URL: https://<contextforge-url>/servers/cff6090b9cd74c0682b08e6666d5f396/mcp

  Claude Desktop / Cursor config:
    {
      "mcpServers": {
        "demo": {
          "url": "https://<contextforge-url>/servers/cff6090b9cd74c0682b08e6666d5f396/mcp"
        }
      }
    }
```

Your MCP endpoint is:

```
https://<contextforge-url>/servers/<virtual-server-uuid>/mcp
```

---

## 6. Test with MCP Inspector

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
| `register-mcp.sh` / `gateway-mcp.sh` fail with "Invalid authentication credentials" | JWT secret changed between deployments | Pin `CONTEXTFORGE_JWT_SECRET` in `.env` and redeploy |
| Scripts do a slow `gcloud` lookup on every run | `CONTEXTFORGE_URL` and `CONTEXTFORGE_JWT_SECRET` not set in `.env` | Add both values to `.env` to skip the lookup |

---

## Resources

- [IBM ContextForge](https://github.com/IBM/mcp-context-forge)
- [FastMCP](https://github.com/jlowin/fastmcp)
- [MCP Inspector](https://github.com/modelcontextprotocol/inspector)
- [Model Context Protocol specification](https://spec.modelcontextprotocol.io)
- [Vertex AI Model Garden](https://console.cloud.google.com/vertex-ai/model-garden)
