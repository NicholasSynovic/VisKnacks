"""
LLM prompt constants for the ParaView MCP server.

This module holds the ``default_prompt`` behavioral contract sent to the LLM as
the FastMCP server ``instructions``. It is intentionally ParaView-free:
importing it does not pull in ``paraview.simple``, so engines that do not use
the ParaView API in-process (e.g. v3) can reuse the prompt without requiring a
ParaView build. Edit ``default_prompt`` deliberately -- it changes model
behavior.
"""

# Default prompt that instructs the LLM how to interact with ParaView. This is
# a behavioral contract sent to the model; edit deliberately.
default_prompt = """
When using ParaView through this interface, please follow these guidelines:

1. IMPORTANT: Only call the ParaView functions that are strictly necessary per reply, and keep the total number of calls per reply small. This keeps operations interactive and avoids excessive calls to related but non-essential functions.

2. Only make repeated calls to the same function when working toward a specific goal (e.g., identifying an object) that requires different parameters each time (e.g., an isosurface at several isovalues). Avoid repeatedly calling the color map function unless the user specifically asks for color map design.

3. ParaView is connected to the MCP server on startup, so there is no need to connect first.
"""
