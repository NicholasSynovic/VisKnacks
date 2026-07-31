"""
extract_functions.py

Extracts top-level function definitions and class method definitions
from a single .py file into a dict mapping fully qualified names to
their source code (including docstrings).

Uses the `ast` module for static analysis.
Requires Python 3.13+.
"""

import argparse
import ast
import sys
from pathlib import Path
from json import dumps


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

        - ``input_file`` (str): Path to the .py file to analyze.

    Example
    -------
    >>> ns = cli(["--input-file", "my_module.py"])
    >>> ns.input_file
    'my_module.py'
    """
    parser = argparse.ArgumentParser(
        prog="extract_functions",
        description=(
            "Extract top-level functions and class methods from a Python "
            "source file into a dict of {FQN: source_code}."
        ),
    )

    parser.add_argument(
        "--input-file",
        required=True,
        type=lambda x: Path(x).absolute(),
        help="Path to the .py file to analyze.",
    )

    return parser.parse_args(args)


def extract_functions(path: Path) -> dict[str, str]:
    """
    Extract top-level functions and class methods from a Python source file.

    Extracts:
        - Top-level function definitions (def / async def)
        - Methods defined directly inside top-level classes
        - Methods in nested classes (e.g., ``module.Outer.Inner.method``)

    Does NOT extract:
        - Nested functions (functions defined inside other functions)

    Parameters
    ----------
    path: Path
        Path to the .py file to analyze.

    Returns
    -------
    dict[str, str]
        A mapping of fully qualified function names to their complete
        source code (including docstrings).
        Keys use the format: ``module.function`` or ``module.Class.method``.

    Raises
    ------
    FileNotFoundError
        If the specified file does not exist.
    ValueError
        If the file does not have a .py extension.

    Example
    -------
    >>> result = extract_functions("my_module.py")
    >>> for name, code in result.items():
    ...     print(f"--- {name} ---")
    ...     print(code)
    """
    if not path.exists():
        raise FileNotFoundError(f"File not found: {path}")
    if path.suffix != ".py":
        raise ValueError(f"Expected a .py file, got: {path.suffix}")

    source = path.read_text(encoding="utf-8")
    source_lines = source.splitlines(keepends=True)

    tree = ast.parse(source, filename=path)

    # Derive the module name from the filename (without .py extension)
    module_name = path.stem

    results: dict[str, str] = {}

    def _extract_source(node: ast.AST) -> str:
        """
        Extract the exact source code for an AST node using line/col offsets.

        Dedents the code based on the node's column offset so that extracted
        methods are returned without excess leading whitespace.

        Parameters
        ----------
        node : ast.AST
            An AST node with lineno, end_lineno, and col_offset attributes.

        Returns
        -------
        str
            The dedented source code for the node.
        """
        start_line = node.lineno - 1  # Convert to 0-indexed
        end_line = node.end_lineno  # Correct for slicing (exclusive)
        col_offset = node.col_offset

        segment_lines = source_lines[start_line:end_line]

        dedented_lines = []
        for line in segment_lines:
            # Strip leading whitespace up to col_offset if it's all whitespace
            if len(line) >= col_offset and line[:col_offset].strip() == "":
                dedented_lines.append(line[col_offset:])
            else:
                dedented_lines.append(line)

        return "".join(dedented_lines).rstrip("\n")

    def _visit_class(node: ast.ClassDef, prefix: str) -> None:
        """
        Visit a class definition and extract its methods.

        Recurses into nested classes to capture their methods as well
        (e.g., ``module.Outer.Inner.method``).

        Parameters
        ----------
        node : ast.ClassDef
            The class AST node to inspect.
        prefix : str
            The dotted name prefix (e.g., "my_module.MyClass").
        """
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.FunctionDef | ast.AsyncFunctionDef):
                fqn = f"{prefix}.{child.name}"
                results[fqn] = _extract_source(child)
                # Do NOT recurse into the function body (skip nested functions)

            elif isinstance(child, ast.ClassDef):
                # Handle nested/inner classes
                nested_prefix = f"{prefix}.{child.name}"
                _visit_class(child, prefix=nested_prefix)

    # -------------------------------------------------------------------
    # Walk only the top-level statements of the module
    # -------------------------------------------------------------------
    for node in ast.iter_child_nodes(tree):
        if isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef):
            # Top-level function
            fqn = f"{module_name}.{node.name}"
            results[fqn] = _extract_source(node)

        elif isinstance(node, ast.ClassDef):
            # Top-level class — extract its methods
            class_prefix = f"{module_name}.{node.name}"
            _visit_class(node, prefix=class_prefix)

    return results


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    namespace = cli()

    try:
        extracted = extract_functions(namespace.input_file)
    except (FileNotFoundError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)

    if not extracted:
        print("No functions or methods found.")
        sys.exit(0)

    print(dumps(obj=extracted, indent=4))
