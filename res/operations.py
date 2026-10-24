#!/usr/bin/env python3

import argparse
import json

import cli_transport as transport
from admin_cli import entry
from batch_operations import recover_operation


def main():
    parser = argparse.ArgumentParser(
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
    args = parser.parse_args()
    transport.configure(args)
    recovered = recover_operation(
        args.url,
        args.token,
        args.operation_id,
    )
    print(json.dumps(recovered, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    entry(main)
