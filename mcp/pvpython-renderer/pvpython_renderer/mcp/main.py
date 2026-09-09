from argparse import Namespace

from fastmcp import FastMCP

from pvpython_renderer.mcp import __prog__
from pvpython_renderer.mcp.cli import cli_parser

MCP_INSTRUCTIONS: str = """
When using ParaView through this interface, please follow these guidelines:

1.  IMPORTANT: Only call the ParaView functions that are strictly necessary per
    reply, and keep the total number of calls per reply small. This keeps
    operations interactive and avoids excessive calls to related but
    non-essential functions.

2.  Only make repeated calls to the same function when working toward a specific
    goal (e.g., identifying an object) that requires different parameters each
    time (e.g., an isosurface at several isovalues). Avoid repeatedly calling
    the color map function unless the user specifically asks for color map
    design.

3.  ParaView is connected to the MCP server on startup, so there is no need to
    connect first.
"""

MCP: FastMCP = FastMCP(name=__prog__, instructions=MCP_INSTRUCTIONS)


def run_mcp_service(server: str, port: int) -> None:
    MCP.run(transport="http", host=server, port=port)


def main() -> None:
    args: Namespace = cli_parser()
    run_mcp_service(server=args.server, port=args.port)


if __name__ == "__main__":
    main()
