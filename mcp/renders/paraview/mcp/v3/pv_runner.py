from argparse import ArgumentParser, Namespace

from paraview.simple import *


def cli_parser() -> Namespace:
    parser: ArgumentParser = ArgumentParser(
        prog="ParaView Runner",
        description="Listens for a reverse connection from a ParaView server and executes arbitrary code",
    )
    parser.add_argument(
        "--pv-host",
        type=str,
        default="localhost",
        help=(
            "Remote ParaView hostname. UNUSED in reverse-connection mode "
            "(the server is told which client to dial back via "
            "--client-host); kept for CLI-signature stability."
        ),
    )
    parser.add_argument(
        "--pv-port",
        type=int,
        default=11111,
        help="Local port to listen on for the server's reverse connection",
    )
    parser.add_argument(
        "--code",
        type=str,
        required=True,
        help="`pvpython` code to execute against the remote",
    )
    return parser.parse_args()


def connect(port: int) -> None:
    """
    Listen for a reverse connection from a ``pvserver``.

    In reverse-connection mode the *runner* (this client) opens a listening
    socket and waits for the server to dial back. This avoids the forward
    client/server hostname-advertisement mismatch (the server advertises its
    system hostname, not ``localhost``), which otherwise refuses every
    connection for ParaView's full connect-retry window.

    Note: ``ReverseConnect`` is passed a **string** port to work around a bug
    in ParaView 5.13.x where the int port is concatenated into a URL string.
    """

    ReverseConnect(str(port))


def main() -> None:
    args: Namespace = cli_parser()

    # Listen for the server's reverse connection. Must happen before pvserver
    # is launched (the runner is the listener in reverse-connection mode).
    connect(port=args.pv_port)

    # Execute the `pvpython` code
    exec(args.code)  # nosec B102 - exec is the intended mechanism for this runner


if __name__ == "__main__":
    main()
