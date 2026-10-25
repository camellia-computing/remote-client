"""Manage Camellia Remote with bounded, receipt-aware administrative commands."""

import argparse
import importlib
import sys
from importlib.metadata import PackageNotFoundError, version

TOOLS = {
    "users": "users",
    "devices": "devices",
    "device-groups": "device_groups",
    "strategies": "strategies",
    "address-books": "address_books",
    "audits": "audits",
    "operations": "operations",
}


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(prog="camellia-remote-admin", description=__doc__)
    parser.add_argument(
        "--version", action="store_true", help="Show the installed package version"
    )
    parser.add_argument("tool", choices=TOOLS)
    if argv == ["--version"]:
        try:
            print(version("camellia-remote-admin"))
            return
        except PackageNotFoundError:
            parser.exit(
                2, "Install the locked CLI package before requesting its version.\n"
            )
    args = parser.parse_args(argv[:1])
    try:
        module = importlib.import_module(f".{TOOLS[args.tool]}", __package__)
        from .outcomes import entry
    except ModuleNotFoundError:
        parser.exit(
            2,
            "CLI dependencies are missing. Install the verified CLI wheel with its hashed requirements, "
            "or run 'uv sync --locked' in the Client checkout.\n",
        )
    remaining = argv[1:]
    entry(lambda: module.main(remaining), json_output="--json" in remaining)


if __name__ == "__main__":
    main()
