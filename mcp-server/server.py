"""
Vertex AI MCP Server
Exposes Gemini capabilities as MCP tools over HTTP (SSE).
Runs on Cloud Run using workload identity — no API keys needed.
"""

import os
import vertexai
from vertexai.generative_models import GenerativeModel
from fastmcp import FastMCP

PROJECT_ID = os.environ["GCP_PROJECT_ID"]
REGION = os.environ.get("VERTEX_REGION", "us-central1")
DEFAULT_MODEL = os.environ.get("VERTEX_MODEL", "gemini-2.5-flash")

vertexai.init(project=PROJECT_ID, location=REGION)

mcp = FastMCP(
    name="vertex-ai-tools",
    instructions="Tools for interacting with Google Gemini via Vertex AI.",
)


@mcp.tool()
def ask(prompt: str, model: str = DEFAULT_MODEL) -> str:
    """Send a prompt to Gemini and return the response."""
    response = GenerativeModel(model).generate_content(prompt)
    return response.text


@mcp.tool()
def summarize(text: str) -> str:
    """Summarize a piece of text using Gemini."""
    prompt = f"Summarize the following text concisely:\n\n{text}"
    response = GenerativeModel(DEFAULT_MODEL).generate_content(prompt)
    return response.text


@mcp.tool()
def translate(text: str, target_language: str) -> str:
    """Translate text into the specified language using Gemini."""
    prompt = f"Translate the following text into {target_language}. Return only the translation:\n\n{text}"
    response = GenerativeModel(DEFAULT_MODEL).generate_content(prompt)
    return response.text


@mcp.tool()
def extract_json(text: str, schema_description: str) -> str:
    """Extract structured data from unstructured text as JSON."""
    prompt = (
        f"Extract the following information from the text and return valid JSON only.\n"
        f"Schema: {schema_description}\n\n"
        f"Text:\n{text}"
    )
    response = GenerativeModel(DEFAULT_MODEL).generate_content(prompt)
    return response.text


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    mcp.run(transport="sse", host="0.0.0.0", port=port)
