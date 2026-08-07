"""
main.py

Builds a FAISS similarity index over ParaView Python API functions and
methods extracted from a project directory. Each function's source code
is embedded using the ``nomic-ai/CodeRankEmbed`` code-embedding model,
and the resulting vectors are stored in an exact (flat) inner-product
FAISS index alongside a metadata sidecar mapping FAISS row IDs back to
the original ``function``/``docstring``/``code`` records.

The resulting index is intended to be queried with raw pvpython
stderr/traceback text to retrieve relevant API usage snippets.
"""

import argparse
import json
import sys
from pathlib import Path

import faiss
import numpy as np
from sentence_transformers import SentenceTransformer

from pvpython_rag.extract_functions import extract_functions

EMBEDDING_MODEL_NAME = "nomic-ai/CodeRankEmbed"
# EMBEDDING_MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"
INDEX_FILENAME = "index.faiss"
METADATA_FILENAME = "metadata.json"


def cli(args: list[str] | None = None) -> argparse.Namespace:
    """
    Parse command-line arguments for the index builder.

    Parameters
    ----------
    args : list[str] | None, optional
        List of argument strings to parse. If None, defaults to
        ``sys.argv[1:]`` (standard CLI behavior).

    Returns
    -------
    argparse.Namespace
        Parsed arguments with the following attributes:

        - ``input_dir`` (str): Path to the Python project root directory
          to extract functions from.
        - ``output_dir`` (str): Path to the directory where the FAISS
          index and metadata sidecar will be written.
        - ``tag`` (str | None): Optional identifier (e.g. a git tag)
          used to suffix the output filenames, producing
          ``index_<tag>.faiss`` and ``metadata_<tag>.json`` instead of
          the default :data:`INDEX_FILENAME`/:data:`METADATA_FILENAME`.

    Example
    -------
    >>> ns = cli(["--input-dir", "my_project/", "--output-dir", "out/"])
    >>> ns.input_dir
    'my_project/'
    >>> ns.output_dir
    'out/'
    >>> ns.tag is None
    True
    """
    parser = argparse.ArgumentParser(
        prog="build_index",
        description=(
            "Extract functions from a Python project directory, embed "
            "their source code with a code-embedding model, and build a "
            "FAISS similarity index for retrieval."
        ),
    )

    parser.add_argument(
        "--input-dir",
        required=True,
        type=str,
        help="Path to the Python project root directory to analyze.",
    )

    parser.add_argument(
        "--output-dir",
        required=True,
        type=str,
        help="Path to the directory to write the FAISS index and metadata sidecar to.",
    )

    parser.add_argument(
        "--tag",
        default=None,
        type=str,
        help=(
            "Optional identifier (e.g. a git tag) to suffix the output "
            "filenames with, producing index_<tag>.faiss and "
            "metadata_<tag>.json instead of the default filenames."
        ),
    )

    return parser.parse_args(args)


def embed_records(
    records: list[dict[str, str]],
    model_name: str = EMBEDDING_MODEL_NAME,
) -> np.ndarray:
    """
    Embed the ``code`` field of each record using a code-embedding model.

    Parameters
    ----------
    records : list[dict[str, str]]
        Function records as returned by
        :func:`pvpython_rag.extract_functions.extract_functions`, each
        containing a ``code`` key.
    model_name : str, optional
        The name of the ``sentence-transformers``-compatible model to
        load. Defaults to :data:`EMBEDDING_MODEL_NAME`.

    Returns
    -------
    np.ndarray
        A 2D float32 array of shape ``(len(records), embedding_dim)``
        containing L2-normalized embeddings, one row per record.
    """
    model = SentenceTransformer(
        model_name,
        trust_remote_code=True,
        device="cuda",
    )

    # Prevent extremely long functions from overwhelming self-attention memory
    model.max_seq_length = 2048

    code_snippets = [record["code"] for record in records]

    embeddings = model.encode(
        code_snippets,
        batch_size=1,  # Prevents out-of-memory errors
        convert_to_numpy=True,
        normalize_embeddings=True,
        show_progress_bar=True,
    )

    return embeddings.astype(np.float32)


def build_faiss_index(embeddings: np.ndarray) -> faiss.IndexFlatIP:
    """
    Build an exact inner-product FAISS index from embeddings.

    Since the embeddings are expected to be L2-normalized, inner
    product is equivalent to cosine similarity.

    Parameters
    ----------
    embeddings : np.ndarray
        A 2D float32 array of shape ``(n_records, embedding_dim)``.

    Returns
    -------
    faiss.IndexFlatIP
        A FAISS flat index populated with the given embeddings, where
        row ``i`` corresponds to ``embeddings[i]``.
    """
    dimension = embeddings.shape[1]
    index = faiss.IndexFlatIP(dimension)
    index.add(embeddings)
    return index


def build_index(input_dir: str, output_dir: str, tag: str | None = None) -> None:
    """
    Extract, embed, index, and persist ParaView function records.

    Parameters
    ----------
    input_dir : str
        Path to the Python project root directory to extract functions
        from.
    output_dir : str
        Path to the directory to write the FAISS index and metadata
        sidecar to. Created if it does not exist.
    tag : str | None, optional
        Optional identifier (e.g. a git tag) to suffix the output
        filenames with. If provided, files are written as
        ``index_<tag>.faiss`` and ``metadata_<tag>.json``; otherwise
        :data:`INDEX_FILENAME` and :data:`METADATA_FILENAME` are used.

    Raises
    ------
    FileNotFoundError
        If ``input_dir`` does not exist.
    NotADirectoryError
        If ``input_dir`` is not a directory.
    ValueError
        If no functions were extracted from ``input_dir``.
    """
    records = extract_functions(input_dir)

    if not records:
        raise ValueError(f"No functions extracted from: {input_dir}")

    embeddings = embed_records(records)
    index = build_faiss_index(embeddings)

    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)

    index_filename = f"index_{tag}.faiss" if tag else INDEX_FILENAME
    metadata_filename = f"metadata_{tag}.json" if tag else METADATA_FILENAME

    faiss.write_index(index, str(output_path / index_filename))

    with (output_path / metadata_filename).open("w", encoding="utf-8") as f:
        json.dump(records, f, indent=4)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    namespace = cli()

    try:
        build_index(namespace.input_dir, namespace.output_dir, namespace.tag)
    except (FileNotFoundError, NotADirectoryError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
