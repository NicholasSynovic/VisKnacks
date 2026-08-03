"""
pvpython-rag MCP server — barebones single-tool scaffold.

Exposes one tool, ``query``, over streamable-http. Currently a stub that
ignores its input and returns "Hello World". Intended to grow into a
RAG-retrieval endpoint over the FAISS indexes built by
``pvpython_rag.main``.
"""

import argparse
from pathlib import Path

from fastmcp import FastMCP

mcp = FastMCP("pvpython-rag")


@mcp.tool()
def query(query: str) -> str:
    """Return a fixed greeting, ignoring the input (stub)."""
    return "Hello World"


def cli(args: list[str] | None = None) -> argparse.Namespace:
    """
    Parse command-line arguments for the pvpython-rag MCP server.

    Parameters
    ----------
    args : list[str] | None, optional
        Argument strings to parse. If None, defaults to ``sys.argv[1:]``
        (standard CLI behavior).

    Returns
    -------
    argparse.Namespace
        Parsed arguments with the following attributes:

        - ``port`` (int): HTTP port the MCP server binds to.
        - ``pv_version`` (str): ParaView version whose index/metadata to
          serve (default ``"5.13"``).
        - ``directory`` (pathlib.Path): Absolute path to a directory of
          FAISS index and metadata files.

    Example
    -------
    >>> ns = cli(["--directory", "."])
    >>> ns.port
    8080
    >>> ns.pv_version
    '5.13'
    >>> ns.directory == Path(".").absolute()
    True
    """
    parser = argparse.ArgumentParser(
        prog="pvpython-rag-mcp",
        description=(
            "Run the pvpython-rag MCP server, serving RAG retrieval over "
            "a directory of prebuilt FAISS indexes and metadata."
        ),
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8080,
        help="HTTP port the MCP server binds to (default: %(default)s).",
    )
    parser.add_argument(
        "--pv-version",
        type=str,
        default="5.13",
        help="ParaView version to serve indexes for (default: %(default)s).",
    )
    parser.add_argument(
        "--directory",
        required=True,
        type=lambda x: Path(x).absolute(),
        help="Path to a directory of FAISS index and metadata files.",
    )

    return parser.parse_args(args)


def run(
    host: str = "localhost",
    port: int = 8080,
    pv_version: str = "5.13",
    directory: Path | None = None,
) -> None:
    """
    Run the MCP server over streamable-http.

    ``pv_version`` and ``directory`` select which prebuilt index/metadata
    to serve; they are accepted now but not yet consumed (retrieval is not
    wired up).
    """
    mcp.run(transport="http", host=host, port=port)


def main() -> None:
    """Parse CLI arguments and run the pvpython-rag MCP server."""
    args = cli()
    run(
        port=args.port,
        pv_version=args.pv_version,
        directory=args.directory,
    )


if __name__ == "__main__":
    main()
