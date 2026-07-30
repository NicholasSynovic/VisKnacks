"""
ParaView MCP - Model Context Protocol server for ParaView (v3 engine).

Unlike v1/v2, the v3 engine never uses ``ParaViewManager`` and is
intentionally import-clean of ``paraview.simple`` (only its ``pv_runner.py``
subprocess imports ParaView). This package therefore does **not** re-export
``ParaViewManager``; doing so would pull in ``paraview.simple`` at import time.
"""

__all__: list[str] = []
