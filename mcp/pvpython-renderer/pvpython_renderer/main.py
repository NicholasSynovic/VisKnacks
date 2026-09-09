"""Command-line entry point for the ParaView MCP server."""

from pvpython_renderer.cli import parse_args
from pvpython_renderer.pv_mcp import run


def main() -> None:
    """
    Parse CLI arguments and run the MCP server over streamable-http.

    Serves the single ``execute_code`` tool at ``http://<server>:<port>/mcp``.
    """
    args = parse_args()
    run(mcp_server=args.server, mcp_port=args.port)


if __name__ == "__main__":
    main()
