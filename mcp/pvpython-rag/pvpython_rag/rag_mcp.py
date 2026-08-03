"""
pvpython-rag MCP server — barebones single-tool scaffold.

Exposes one tool, ``query``, over streamable-http. Currently a stub that
ignores its input and returns "Hello World". Intended to grow into a
RAG-retrieval endpoint over the FAISS indexes built by
``pvpython_rag.main``.
"""

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

import faiss

from fastmcp import FastMCP

mcp = FastMCP("pvpython-rag")


@dataclass
class VectorDB:
    """
    A loaded ParaView vector database.

    Attributes
    ----------
    version : str
        The normalized, ``v``-prefixed version identifier (e.g.
        ``"v5.13.3"``) the index and metadata were loaded for.
    index : faiss.Index
        The FAISS similarity index (``IndexFlatIP``, 768-dimensional).
    metadata : list[dict]
        Per-record ``{function, docstring, code}`` dicts. Row ``i`` of
        ``index`` corresponds to ``metadata[i]``.
    """

    version: str
    index: faiss.Index
    metadata: list[dict]


# Populated eagerly at startup by ``run`` and reused by the ``query`` tool.
_VECTOR_DB: VectorDB | None = None


@mcp.tool()
def query(query: str) -> str:
    """Return a fixed greeting, ignoring the input (stub)."""
    return "Hello World"


def _normalize_version(pv_version: str) -> str:
    """
    Return ``pv_version`` with exactly one leading ``v``.

    ``"5.13.3"`` and ``"v5.13.3"`` both normalize to ``"v5.13.3"``,
    matching the ``index_v<version>.faiss`` / ``metadata_v<version>.json``
    on-disk naming.
    """
    return "v" + pv_version.lstrip("v")


def load_vector_db(directory: Path, pv_version: str) -> VectorDB:
    """
    Load the FAISS index and metadata for a specific ParaView version.

    Parameters
    ----------
    directory : pathlib.Path
        Directory containing ``index_v<version>.faiss`` and
        ``metadata_v<version>.json`` file pairs.
    pv_version : str
        The ParaView version to load, with or without a leading ``v``
        (e.g. ``"5.13.3"`` or ``"v5.13.3"``). Matched exactly against the
        full patch version in the filenames.

    Returns
    -------
    VectorDB
        The loaded index and metadata.

    Raises
    ------
    FileNotFoundError
        If ``directory`` is not a directory, or the index/metadata file
        for ``pv_version`` does not exist.
    ValueError
        If the metadata record count does not match the index size.
    """
    version = _normalize_version(pv_version)

    if not directory.is_dir():
        raise FileNotFoundError(
            f"vector database directory does not exist or is not a "
            f"directory: {directory}"
        )

    index_path = directory / f"index_{version}.faiss"
    metadata_path = directory / f"metadata_{version}.json"

    missing = [str(p) for p in (index_path, metadata_path) if not p.is_file()]
    if missing:
        raise FileNotFoundError(
            f"no vector database found for version {version!r} in "
            f"{directory}; missing: {', '.join(missing)}"
        )

    index = faiss.read_index(str(index_path))

    with metadata_path.open(encoding="utf-8") as f:
        metadata = json.load(f)

    if len(metadata) != index.ntotal:
        raise ValueError(
            f"vector database for {version!r} is inconsistent: "
            f"{len(metadata)} metadata records but {index.ntotal} index "
            f"entries ({metadata_path} vs {index_path})"
        )

    return VectorDB(version=version, index=index, metadata=metadata)


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
          serve (default ``"5.13.3"``).
        - ``directory`` (pathlib.Path): Absolute path to a directory of
          FAISS index and metadata files.

    Example
    -------
    >>> ns = cli(["--directory", "."])
    >>> ns.port
    8080
    >>> ns.pv_version
    '5.13.3'
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
        default="5.13.3",
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
    pv_version: str = "5.13.3",
    directory: Path | None = None,
) -> None:
    """
    Load the vector database for ``pv_version`` and run the MCP server.

    The FAISS index and metadata are loaded eagerly from ``directory``
    before the server starts, so a missing or inconsistent database fails
    fast. The loaded database is held in memory for the ``query`` tool to
    use (retrieval itself is not yet wired up).

    Raises
    ------
    FileNotFoundError
        If ``directory`` or the index/metadata files for ``pv_version``
        are missing.
    ValueError
        If the loaded index and metadata are inconsistent.
    """
    global _VECTOR_DB
    _VECTOR_DB = load_vector_db(directory, pv_version)
    print(
        f"Loaded vector database {_VECTOR_DB.version} "
        f"({len(_VECTOR_DB.metadata)} records, "
        f"dim {_VECTOR_DB.index.d}) from {directory}",
        file=sys.stderr,
    )
    mcp.run(transport="http", host=host, port=port)


def main() -> None:
    """Parse CLI arguments and run the pvpython-rag MCP server."""
    args = cli()
    try:
        run(
            port=args.port,
            pv_version=args.pv_version,
            directory=args.directory,
        )
    except (FileNotFoundError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
