"""
ParaView MCP - Model Context Protocol server for ParaView
"""

from paraview_mcp.manager import ParaViewManager

# Display name for the FastMCP server (see pv_mcp.py). Do NOT override the
# module dunder ``__name__`` here: doing so breaks ``from paraview_mcp.v2
# import <submodule>`` because the import machinery derives the submodule's
# fully-qualified name from the package ``__name__``.
MCP_SERVER_NAME: str = "ParaView"

__all__: list[str] = ["ParaViewManager", "MCP_SERVER_NAME"]
