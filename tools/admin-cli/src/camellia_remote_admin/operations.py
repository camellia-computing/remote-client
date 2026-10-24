import argparse
import json

from . import transport
from .batch_operations import recover_operation


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="camellia-remote-admin operations",
        description="Recover a durable management mutation receipt after response loss",
    )
    parser.add_argument("--url", required=True, help="Management server URL")
    parser.add_argument("--token", required=True, help="Management API bearer token")
    parser.add_argument(
        "--operation-id",
        required=True,
        help="Canonical UUIDv4 printed before the original mutation",
    )
    transport.add_options(parser)
    args = parser.parse_args(argv)
    transport.configure(args)
    recovered = recover_operation(
        args.url,
        args.token,
        args.operation_id,
    )
    print(json.dumps(recovered, ensure_ascii=False, sort_keys=True))
