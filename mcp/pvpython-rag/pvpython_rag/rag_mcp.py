"""
pvpython-rag MCP server — code-retrieval endpoint.

Exposes one tool, ``query``, over streamable-http. The tool embeds an
incoming natural-language query with the same ``nomic-ai/CodeRankEmbed``
model used to build the indexes, searches the loaded FAISS vector database
for a specific ParaView version, and returns the top matching
``{function, docstring, code, score}`` records built by
``pvpython_rag.main``.
"""

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

import faiss
import numpy as np
from sentence_transformers import SentenceTransformer

from fastmcp import FastMCP

# Embedding configuration. These MUST match the values used to build the
# indexes in ``pvpython_rag.main`` (same model, sequence length, and
# normalization), or query embeddings will not be comparable to the stored
# document embeddings.
EMBEDDING_MODEL_NAME = "nomic-ai/CodeRankEmbed"
MODEL_MAX_SEQ_LENGTH = 2048

# CodeRankEmbed is asymmetric: *queries* must carry this task-instruction
# prefix, while the indexed *documents* (raw code) must not. Omitting it
# silently degrades retrieval quality.
QUERY_PREFIX = "Represent this query for searching relevant code: "

# Default number of results returned by the ``query`` tool.
DEFAULT_TOP_K = 5

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
_MODEL: SentenceTransformer | None = None


@mcp.tool()
def query(query: str, k: int = DEFAULT_TOP_K) -> list[dict]:
    """
    Search the loaded vector database for code relevant to ``query``.

    The query is embedded with the same ``nomic-ai/CodeRankEmbed`` model
    used to build the index (prefixed with the required query
    task-instruction and L2-normalized), then matched against the FAISS
    index via cosine similarity.

    Parameters
    ----------
    query : str
        A natural-language description of the desired functionality. The
        required CodeRankEmbed query prefix is added internally; callers
        pass plain text.
    k : int, optional
        Maximum number of results to return, ordered by descending
        similarity. Defaults to :data:`DEFAULT_TOP_K`. Values ``<= 0``
        return an empty list; larger values are clamped to the index size.

    Returns
    -------
    list[dict]
        Up to ``k`` records, each a ``{function, docstring, code, score}``
        dict where ``score`` is the cosine similarity (higher is better).

    Raises
    ------
    RuntimeError
        If the server was not initialized (vector database or embedding
        model not loaded).
    """
    if _VECTOR_DB is None or _MODEL is None:
        raise RuntimeError(
            "server not initialized: vector database and embedding model "
            "must be loaded before querying"
        )

    if k <= 0:
        return []

    k = min(k, _VECTOR_DB.index.ntotal)

    query_embedding = _MODEL.encode(
        [QUERY_PREFIX + query],
        normalize_embeddings=True,
        convert_to_numpy=True,
    ).astype(np.float32)

    scores, indices = _VECTOR_DB.index.search(query_embedding, k)

    results: list[dict] = []
    for idx, score in zip(indices[0], scores[0]):
        # FAISS pads with -1 when fewer than k results are available.
        if idx == -1:
            continue
        record = _VECTOR_DB.metadata[idx]
        results.append({**record, "score": float(score)})

    return results


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


def load_model() -> SentenceTransformer:
    """
    Load the query-embedding model, matching the index builder.

    Uses the same model, device, and sequence length as
    :func:`pvpython_rag.main.embed_records`, so query embeddings are
    directly comparable to the stored document embeddings.

    Returns
    -------
    SentenceTransformer
        The loaded ``nomic-ai/CodeRankEmbed`` model on ``cuda``.

    Notes
    -----
    Loading requires a CUDA-capable GPU (no CPU fallback, matching the
    builder) and, on first use, network access to download the model.
    """
    model = SentenceTransformer(
        EMBEDDING_MODEL_NAME,
        trust_remote_code=True,
        device="cuda",
    )
    model.max_seq_length = MODEL_MAX_SEQ_LENGTH
    return model


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
    Load the vector database and embedding model, then run the server.

    The FAISS index, metadata, and query-embedding model are loaded
    eagerly from ``directory`` before the server starts, so a missing or
    inconsistent database or an unavailable model fails fast. Both are
    held in memory for the ``query`` tool to reuse on every call.

    Raises
    ------
    FileNotFoundError
        If ``directory`` or the index/metadata files for ``pv_version``
        are missing.
    ValueError
        If the loaded index and metadata are inconsistent.
    RuntimeError
        If the embedding model cannot be loaded (e.g. no CUDA device).
    """
    global _VECTOR_DB, _MODEL
    _VECTOR_DB = load_vector_db(directory, pv_version)
    print(
        f"Loaded vector database {_VECTOR_DB.version} "
        f"({len(_VECTOR_DB.metadata)} records, "
        f"dim {_VECTOR_DB.index.d}) from {directory}",
        file=sys.stderr,
    )
    _MODEL = load_model()
    print(
        f"Loaded embedding model {EMBEDDING_MODEL_NAME} on cuda",
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
    except (FileNotFoundError, ValueError, RuntimeError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
