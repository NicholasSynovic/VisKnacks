"""
extract_functions.py

Extracts top-level function definitions and class method definitions
from an entire Python project directory into a list of dicts, each
containing the fully qualified name, docstring, and source code.

Uses the `ast` module for static analysis.
Requires Python 3.10+.
"""

import argparse
import ast
import sys
from pathlib import Path
import pandas as pd

# ---------------------------------------------------------------------------
# Default directories and patterns to exclude during traversal
# ---------------------------------------------------------------------------
DEFAULT_EXCLUDE_DIRS: frozenset[str] = frozenset(
    {
        "__pycache__",
        ".git",
        ".hg",
        ".svn",
        ".venv",
        "venv",
        "env",
        ".env",
        ".tox",
        ".nox",
        ".mypy_cache",
        ".pytest_cache",
        ".ruff_cache",
        "node_modules",
        "build",
        "dist",
        "site-packages",
    }
)

DEFAULT_EXCLUDE_SUFFIXES: frozenset[str] = frozenset(
    {
        ".egg-info",
    }
)


def cli(args: list[str] | None = None) -> argparse.Namespace:
    """
    Parse command-line arguments for the function extractor.

    Parameters
    ----------
    args : list[str] | None, optional
        List of argument strings to parse. If None, defaults to
        ``sys.argv[1:]`` (standard CLI behavior).

    Returns
    -------
    argparse.Namespace
        Parsed arguments with the following attributes:

        - ``input_dir`` (str): Path to the Python project root directory.

    Example
    -------
    >>> ns = cli(["--input-dir", "my_project/"])
    >>> ns.input_dir
    'my_project/'
    """
    parser = argparse.ArgumentParser(
        prog="extract_functions",
        description=(
            "Extract top-level functions and class methods from all Python "
            "source files in a project directory into a JSON list of "
            "{function, docstring, code} records."
        ),
    )

    parser.add_argument(
        "--input-dir",
        required=True,
        type=str,
        help="Path to the Python project root directory to analyze.",
    )

    return parser.parse_args(args)


def _should_exclude_dir(dir_path: Path) -> bool:
    """
    Determine whether a directory should be excluded from traversal.

    Checks the directory name against the default exclusion list and
    common suffixes (e.g., ``.egg-info``).

    Parameters
    ----------
    dir_path : Path
        The directory path to evaluate.

    Returns
    -------
    bool
        True if the directory should be excluded, False otherwise.
    """
    name = dir_path.name

    # Exclude hidden directories (starting with '.')
    if name.startswith(".") and name not in {".", ".."}:
        return True

    # Exclude by exact name match
    if name in DEFAULT_EXCLUDE_DIRS:
        return True

    # Exclude by suffix match (e.g., *.egg-info)
    if any(name.endswith(suffix) for suffix in DEFAULT_EXCLUDE_SUFFIXES):
        return True

    return False


def _collect_python_files(root: Path) -> list[Path]:
    """
    Recursively collect all .py files under the given root directory.

    Skips directories that match the default exclusion rules.

    Parameters
    ----------
    root : Path
        The root directory to search.

    Returns
    -------
    list[Path]
        Sorted list of paths to .py files found under the root.
    """
    py_files: list[Path] = []

    for item in sorted(root.iterdir()):
        if item.is_dir():
            if not _should_exclude_dir(item):
                py_files.extend(_collect_python_files(item))
        elif item.is_file() and item.suffix == ".py":
            py_files.append(item)

    return py_files


def _resolve_module_fqn(filepath: Path, root: Path) -> str:
    """
    Derive the fully qualified module name relative to the project root.

    For ``__init__.py`` files, the module name is the package path itself
    (mirroring Python's import semantics). For all other files, the stem
    is appended to the package path.

    Parameters
    ----------
    filepath : Path
        Absolute or relative path to the .py file.
    root : Path
        The project root directory.

    Returns
    -------
    str
        Dotted module name relative to root.

    Examples
    --------
    >>> _resolve_module_fqn(Path("proj/core/engine.py"), Path("proj"))
    'core.engine'
    >>> _resolve_module_fqn(Path("proj/core/__init__.py"), Path("proj"))
    'core'
    >>> _resolve_module_fqn(Path("proj/main.py"), Path("proj"))
    'main'
    """
    relative = filepath.relative_to(root)

    if relative.name == "__init__.py":
        # Package init — FQN is the directory path
        parts = relative.parent.parts
    else:
        # Regular module — FQN includes the stem
        parts = (*relative.parent.parts, relative.stem)

    return ".".join(parts)


def _extract_source(
    node: ast.AST,
    source_lines: list[str],
) -> str:
    """
    Extract the exact source code and remove the docstring for an AST node using line/col offsets.

    Dedents the code based on the node's column offset so that extracted
    methods are returned without excess leading whitespace.

    Parameters
    ----------
    node : ast.AST
        An AST node with lineno, end_lineno, and col_offset attributes.
    source_lines : list[str]
        The full source file split into lines (with line endings preserved).

    Returns
    -------
    str
        The dedented source code for the node.
    """

    start_line = node.lineno - 1
    end_line = node.end_lineno
    col_offset = node.col_offset

    # If this node has a body, check whether first statement is a docstring
    body = getattr(node, "body", None)
    if body:
        first_stmt = body[0]
        if (
            isinstance(first_stmt, ast.Expr)
            and isinstance(first_stmt.value, ast.Constant)
            and isinstance(first_stmt.value.value, str)
        ):
            # Skip docstring lines
            doc_end_line = first_stmt.end_lineno
            start_line = doc_end_line

    segment_lines = source_lines[start_line:end_line]

    dedented_lines = []
    for line in segment_lines:
        if len(line) >= col_offset and line[:col_offset].strip() == "":
            dedented_lines.append(line[col_offset:])
        else:
            dedented_lines.append(line)

    return "".join(dedented_lines).rstrip("\n")


def _extract_docstring(
    node: ast.FunctionDef | ast.AsyncFunctionDef,
) -> str:
    """
    Extract the docstring from a function or async function AST node.

    Parameters
    ----------
    node : ast.FunctionDef | ast.AsyncFunctionDef
        The function node to extract the docstring from.

    Returns
    -------
    str
        The docstring text, or an empty string if no docstring is present.
    """
    docstring = ast.get_docstring(node)
    return docstring if docstring is not None else ""


def _extract_from_file(
    filepath: Path,
    root: Path,
) -> list[dict[str, str]]:
    """
    Extract top-level functions and class methods from a single .py file.

    Parameters
    ----------
    filepath : Path
        Path to the .py file to analyze.
    root : Path
        The project root directory (used for FQN resolution).

    Returns
    -------
    list[dict[str, str]]
        A list of dicts, each with keys ``function``, ``docstring``,
        and ``code``.
    """
    source = filepath.read_text(encoding="utf-8")
    source_lines = source.splitlines(keepends=True)

    try:
        tree = ast.parse(source, filename=str(filepath))
    except SyntaxError as exc:
        print(
            f"Warning: Skipping {filepath} due to syntax error: {exc}",
            file=sys.stderr,
        )
        return []

    module_fqn = _resolve_module_fqn(filepath, root)
    results: list[dict[str, str]] = []

    def _make_record(
        fqn: str,
        node: ast.FunctionDef | ast.AsyncFunctionDef,
    ) -> dict[str, str]:
        """
        Build a function record dict from an AST node.

        Parameters
        ----------
        fqn : str
            The fully qualified name for the function.
        node : ast.FunctionDef | ast.AsyncFunctionDef
            The function AST node.

        Returns
        -------
        dict[str, str]
            Dict with keys ``function``, ``docstring``, and ``code``.
        """
        return {
            "function": fqn,
            "docstring": _extract_docstring(node),
            "code": _extract_source(node, source_lines),
        }

    def _visit_class(node: ast.ClassDef, prefix: str) -> None:
        """
        Visit a class definition and extract its methods.

        Recurses into nested classes to capture their methods as well.

        Parameters
        ----------
        node : ast.ClassDef
            The class AST node to inspect.
        prefix : str
            The dotted name prefix (e.g., "core.engine.MyClass").
        """
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.FunctionDef | ast.AsyncFunctionDef):
                fqn = f"{prefix}.{child.name}"
                results.append(_make_record(fqn, child))

            elif isinstance(child, ast.ClassDef):
                nested_prefix = f"{prefix}.{child.name}"
                _visit_class(child, prefix=nested_prefix)

    # -------------------------------------------------------------------
    # Walk only the top-level statements of the module
    # -------------------------------------------------------------------
    for node in ast.iter_child_nodes(tree):
        if isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef):
            fqn = f"{module_fqn}.{node.name}" if module_fqn else node.name
            results.append(_make_record(fqn, node))

        elif isinstance(node, ast.ClassDef):
            class_prefix = f"{module_fqn}.{node.name}" if module_fqn else node.name
            _visit_class(node, prefix=class_prefix)

    return results


def extract_functions(project_dir: str) -> list[dict[str, str]]:
    """
    Extract top-level functions and class methods from all Python files
    in a project directory.

    Recursively traverses the directory, skipping common non-source
    directories (e.g., ``__pycache__``, ``.venv``, ``build``).

    Parameters
    ----------
    project_dir : str
        Path to the Python project root directory.

    Returns
    -------
    list[dict[str, str]]
        A list of dicts, each containing:

        - ``function`` (str): Fully qualified name relative to the
          project root (e.g., ``core.engine.Engine.run``).
        - ``docstring`` (str): The function's docstring, or an empty
          string if none is present.
        - ``code`` (str): The complete source code of the function
          (including the docstring as it appears in source).

    Raises
    ------
    FileNotFoundError
        If the specified directory does not exist.
    NotADirectoryError
        If the specified path is not a directory.

    Example
    -------
    >>> results = extract_functions("my_project/")
    >>> for record in results:
    ...     print(record["function"])
    ...     print(record["docstring"][:50])
    ...     print(record["code"][:80])
    ...     print()
    """
    root = Path(project_dir).resolve()

    if not root.exists():
        raise FileNotFoundError(f"Directory not found: {project_dir}")
    if not root.is_dir():
        raise NotADirectoryError(f"Not a directory: {project_dir}")

    py_files = _collect_python_files(root)

    results: list[dict[str, str]] = []
    for py_file in py_files:
        file_results = _extract_from_file(py_file, root)
        results.extend(file_results)

    return results


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    namespace = cli()

    try:
        extracted = extract_functions(namespace.input_dir)
    except (FileNotFoundError, NotADirectoryError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)

    df: pd.DataFrame = pd.DataFrame(data=extracted)
    print(df)
