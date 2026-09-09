from importlib.metadata import PackageNotFoundError, version

# ``pv_mcp.py`` and ``pv_runner.py`` are intentionally import-clean of
# ``paraview.simple``. Only ``pv_runner.py``, executed as a subprocess under
# ``pvpython``, imports ParaView at runtime.

__prog__: str = "pvpython-renderer-mcp"


def _package_version() -> str:
    """Return the installed ``pvpython-renderer`` version, or 'unknown'."""
    try:
        return version("pvpython-renderer")
    except PackageNotFoundError:  # pragma: no cover - not installed as a dist
        return "unknown"


__doi__: str = "10.48550/arXiv.2505.07064"
__version__: str = _package_version()
