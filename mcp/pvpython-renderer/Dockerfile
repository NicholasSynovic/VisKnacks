# syntax=docker/dockerfile:1
#
# pvpython-renderer MCP server — headless ParaView container.
#
# Build:
#   docker build -t pvpython-renderer:latest .
#
# Run:
#   docker run --rm -p 8080:8080 \
#       -v paraview-logs:/home/pvuser/paraview_logs \
#       pvpython-renderer:latest
#
# The MCP endpoint is then at http://localhost:8080/mcp
#
# Rendering is software-only (Mesa llvmpipe via the ParaView `osmesa` build);
# no GPU, X server, or host driver is required. See
# `environment.container.yaml` for why this differs from `environment.yaml`.

FROM condaforge/miniforge3:24.11.3-2

# `paraview` is conda-only (it cannot be pip-installed), so the conda env IS
# the runtime: its Python 3.10 interpreter is what the console script runs on.
COPY environment.container.yaml /tmp/environment.container.yaml
RUN conda env create --file /tmp/environment.container.yaml \
    && conda clean --all --yes \
    && rm -f /tmp/environment.container.yaml

# Put the env's bin on PATH rather than relying on `conda activate`. This is
# load-bearing: pv_mcp.py resolves the ParaView binaries with
# shutil.which("pvpython") / shutil.which("pvserver") at call time, so they
# must be on PATH of the server process and of every subprocess it spawns.
ENV PATH=/opt/conda/envs/pvpython_renderer/bin:$PATH

# Force the software GL path. The osmesa build has no hardware driver to fall
# back to, and these make that explicit rather than implicit.
ENV LIBGL_ALWAYS_SOFTWARE=1 \
    GALLIUM_DRIVER=llvmpipe

# Fail the build loudly if the osmesa package does not actually provide a
# working headless pvserver/pvpython pair, rather than shipping an image that
# only breaks on the first execute_code call.
RUN pvserver --version \
    && pvpython -c "from paraview.simple import *; print('paraview.simple OK')"

WORKDIR /app

# Copy only what the package build needs, so dependency layers stay cached
# when the source changes.
COPY pyproject.toml README.md ./
COPY pvpython_renderer/ ./pvpython_renderer/

# Non-editable install; the dev dependency group is intentionally skipped.
# This registers the `pvpython-renderer-mcp` console script.
RUN pip install --no-cache-dir . \
    && python -c "import pvpython_renderer.pv_mcp"

# Run as a non-root user. HOME must be writable: logger.py and pv_mcp.py both
# write to ~/paraview_logs (main log plus per-call runner/pvserver logs).
# uid 1001, not 1000: the base image already ships an `ubuntu` user at 1000.
RUN useradd --create-home --uid 1001 --shell /bin/bash pvuser \
    && mkdir -p /home/pvuser/paraview_logs \
    && chown -R pvuser:pvuser /home/pvuser
USER pvuser
ENV HOME=/home/pvuser
VOLUME ["/home/pvuser/paraview_logs"]

EXPOSE 8080

# A plain HTTP GET on /mcp returns 406 without the MCP negotiation headers, so
# it is not a usable probe. Check that the transport is accepting TCP instead.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import socket,sys; s=socket.create_connection(('127.0.0.1',8080),3); s.close()" \
    || exit 1

# Bind 0.0.0.0, not the `--server localhost` default: localhost inside the
# container's network namespace is unreachable from a published port.
CMD ["pvpython-renderer-mcp", "--server", "0.0.0.0", "--port", "8080"]
