"""
pvpython-rag MCP server — barebones single-tool scaffold.

Exposes one tool, ``query``, over streamable-http. Currently a stub that
ignores its input and returns "Hello World". Intended to grow into a
RAG-retrieval endpoint over the FAISS indexes built by
``pvpython_rag.main``.
"""

from fastmcp import FastMCP

mcp = FastMCP("pvpython-rag")


@mcp.tool()
def query(query: str) -> str:
    """Return a fixed greeting, ignoring the input (stub)."""
    return "Hello World"


def run(host: str = "localhost", port: int = 8080) -> None:
    """Run the MCP server over streamable-http."""
    mcp.run(transport="http", host=host, port=port)


if __name__ == "__main__":
    run()
