"""CLI outcome boundary. Only validated receipts can confirm a mutation."""

import hashlib
import json
import sys
import uuid
from collections.abc import Callable
from contextlib import redirect_stdout
from dataclasses import dataclass, field
from enum import IntEnum

import requests

from . import transport


class ExitCode(IntEnum):
    SUCCESS = 0
    UNKNOWN = 1
    INVALID = 2
    NO_MATCH = 3
    PARTIAL = 4
    REMOTE_ERROR = 5
    CANCELLED = 130


class CliError(SystemExit):
    def __init__(self, message, code=ExitCode.UNKNOWN, *, receipt=None, summary=None):
        super().__init__(int(code))
        self.message = message
        self.receipt = receipt
        self.summary = summary
        if summary is not None:
            summary.update(
                result="cancelled" if self.code == ExitCode.CANCELLED else "failed",
                exit_code=self.code,
            )


def add_options(parser):
    transport.add_options(parser)
    parser.add_argument(
        "--json",
        action="store_true",
        help="Write one JSON result to stdout; progress goes to stderr",
    )
    parser.add_argument(
        "--allow-empty",
        action="store_true",
        help="Explicitly permit a zero-target mutation without sending a request",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Confirm the frozen multi-target snapshot without prompting",
    )


def split_targets(value, label):
    if value is None:
        return []
    values = [item.strip() for item in value.split(",")]
    if any(not item for item in values):
        raise CliError(f"{label} contains an empty target", ExitCode.INVALID)
    if len(set(values)) != len(values):
        raise CliError(f"{label} contains duplicate targets", ExitCode.INVALID)
    return values


def read_json(response):
    if response.status_code != 200:
        raise CliError(f"Management HTTP {response.status_code}", ExitCode.REMOTE_ERROR)
    try:
        body = response.json()
    except ValueError:
        raise CliError("Management response is not JSON") from None
    if not isinstance(body, (dict, list)) or isinstance(body, dict) and "error" in body:
        raise CliError(
            "Management response is not a successful document", ExitCode.REMOTE_ERROR
        )
    return body


def read_page(response):
    body = read_json(response)
    if (
        not isinstance(body, dict)
        or not isinstance(body.get("data"), list)
        or any(not isinstance(row, dict) for row in body["data"])
        or type(body.get("total")) is not int
        or body["total"] < 0
    ):
        raise CliError("Management inventory page is malformed")
    return body


@dataclass
class Mutation:
    # Deliberately excludes form bodies, passwords, tokens and response payloads.
    targets: dict
    invoke: Callable[[str], dict]
    operation_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    generations: dict = field(default_factory=dict)


def run_mutations(operation, mutations, *, allow_empty=False, yes=False):
    requested = {}
    snapshot = []
    seen = set()
    operation_ids = set()
    for mutation in mutations:
        if not isinstance(mutation.operation_id, str):
            raise CliError("Every operation needs a canonical UUIDv4", ExitCode.INVALID)
        try:
            parsed_id = uuid.UUID(mutation.operation_id)
        except (ValueError, AttributeError):
            raise CliError(
                "Every operation needs a canonical UUIDv4", ExitCode.INVALID
            ) from None
        if (
            parsed_id.version != 4
            or str(parsed_id) != mutation.operation_id
            or mutation.operation_id in operation_ids
        ):
            raise CliError(
                "Operation IDs must be unique canonical UUIDv4 values", ExitCode.INVALID
            )
        operation_ids.add(mutation.operation_id)
        for kind, identifiers in mutation.targets.items():
            for identifier in identifiers:
                if (
                    not isinstance(identifier, str)
                    or not identifier
                    or (kind, identifier) in seen
                ):
                    raise CliError(
                        "Mutation targets must be unique non-empty identifiers",
                        ExitCode.INVALID,
                    )
                seen.add((kind, identifier))
            requested[kind] = requested.get(kind, 0) + len(identifiers)
        snapshot.append(
            {"targets": mutation.targets, "generations": mutation.generations}
        )
    digest = hashlib.sha256(
        json.dumps(snapshot, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    summary = {
        "version": 1,
        "operation": operation,
        "result": "success",
        "exit_code": 0,
        "target_digest": digest,
        "requested": requested,
        "applied": dict.fromkeys(requested, 0),
        "operations": [],
        "not_attempted": [m.targets for m in mutations],
    }
    if not seen:
        if not allow_empty:
            raise CliError(
                "Mutation matched no targets", ExitCode.NO_MATCH, summary=summary
            )
        return summary
    print(f"Target snapshot digest: {digest}", flush=True)
    if len(seen) > 1 and not yes:
        try:
            confirmed = (
                input(f"Apply {operation} to {len(seen)} targets? Type Y to confirm: ")
                .strip()
                .upper()
                == "Y"
            )
        except (EOFError, KeyboardInterrupt):
            confirmed = False
        if not confirmed:
            raise CliError(
                "Operation cancelled before mutation",
                ExitCode.CANCELLED,
                summary=summary,
            )
    for index, mutation in enumerate(mutations):
        record = {
            "operation_id": mutation.operation_id,
            "targets": mutation.targets,
            "state": "unknown",
        }
        summary["operations"].append(record)
        summary["not_attempted"] = [m.targets for m in mutations[index + 1 :]]
        try:
            receipt = mutation.invoke(mutation.operation_id)
        except (SystemExit, requests.RequestException, KeyboardInterrupt) as exc:
            receipt = getattr(exc, "receipt", None)
            if (isinstance(exc, transport.TransportFailure) and not exc.sent) or (
                isinstance(exc, KeyboardInterrupt)
                and getattr(exc, "request_sent", True) is False
            ):
                record["state"] = "not_attempted"
                summary["not_attempted"].insert(0, mutation.targets)
            if isinstance(exc, transport.TransportFailure):
                record.update(transport_failure=exc.kind, request_sent=exc.sent)
            if receipt is not None:
                record["state"] = (
                    "partial" if any(receipt["applied"].values()) else "rejected"
                )
                record["applied"] = receipt["applied"]
                for kind, count in receipt["applied"].items():
                    summary["applied"][kind] += count
            code = (
                ExitCode.PARTIAL
                if any(summary["applied"].values())
                else (
                    ExitCode.CANCELLED
                    if isinstance(exc, KeyboardInterrupt)
                    else (
                        ExitCode.REMOTE_ERROR
                        if record["state"] == "not_attempted"
                        else getattr(exc, "code", ExitCode.UNKNOWN)
                    )
                )
            )
            if not isinstance(code, int) or code == 0:
                code = ExitCode.UNKNOWN
            raise CliError(
                "Mutation stopped; recover unknown operation IDs before retrying or compensating",
                code,
                summary=summary,
            ) from None
        expected = {kind: len(ids) for kind, ids in mutation.targets.items()}
        # The route-specific wrapper has already verified actor/operation/digests.
        # This final boundary still checks exact requested/applied counts.
        if (
            not isinstance(receipt, dict)
            or receipt.get("operation_id") != mutation.operation_id
            or receipt.get("requested") != expected
            or receipt.get("applied") != expected
            or not isinstance(receipt.get("result_digest"), str)
            or any(
                type(count) is not int for count in receipt.get("applied", {}).values()
            )
        ):
            raise CliError(
                "Mutation did not return its exact completion receipt",
                ExitCode.PARTIAL
                if any(summary["applied"].values())
                else ExitCode.UNKNOWN,
                summary=summary,
            )
        record.update(
            state="applied",
            applied=receipt["applied"],
            result_digest=receipt["result_digest"],
        )
        for kind, count in receipt["applied"].items():
            summary["applied"][kind] += count
    return summary


def control_mutations(rows, resource, callback, *, operation_id=None):
    """Preflight every target before a multi-request operation can partially commit."""
    if operation_id is not None and len(rows) != 1:
        raise CliError("--operation-id requires exactly one target", ExitCode.INVALID)
    mutations = []
    for row in rows:
        generation = row.get("mutation_generation")
        if type(generation) is not int or generation < 0:
            raise CliError(
                "Every target needs an observed mutation generation", ExitCode.INVALID
            )
        mutation = Mutation(
            {resource: [row.get("guid")]},
            lambda key, row=row: callback(row, key),
            generations={resource: {row.get("guid"): generation}},
        )
        if operation_id is not None:
            mutation.operation_id = operation_id
        mutations.append(mutation)
    return mutations


def entry(main, *, json_output=None):
    if json_output is None:
        json_output = "--json" in sys.argv[1:]
    try:
        with (
            transport.command_transport(),
            redirect_stdout(sys.stderr) if json_output else redirect_stdout(sys.stdout),
        ):
            result = main()
    except CliError as exc:
        result = exc.summary or {"version": 1}
        result.update(
            result="cancelled" if exc.code == ExitCode.CANCELLED else "failed",
            exit_code=exc.code,
            message=exc.message,
        )
        print(
            json.dumps(result, ensure_ascii=False),
            file=sys.stdout if json_output else sys.stderr,
        )
        raise SystemExit(exc.code) from None
    except transport.TransportFailure as exc:
        code = (
            ExitCode.INVALID
            if exc.kind == "invalid_request"
            else ExitCode.UNKNOWN
            if exc.sent
            else ExitCode.REMOTE_ERROR
        )
        result = {
            "version": 1,
            "result": "failed",
            "exit_code": int(code),
            "message": "Management transport failed; no mutation result is confirmed",
            "reason": exc.kind,
            "request_sent": exc.sent,
            "http_status": exc.status,
        }
        print(json.dumps(result), file=sys.stdout if json_output else sys.stderr)
        raise SystemExit(code) from None
    except requests.RequestException:
        result = {
            "version": 1,
            "result": "failed",
            "exit_code": int(ExitCode.UNKNOWN),
            "message": "Management request failed; no mutation result is confirmed",
        }
        print(json.dumps(result), file=sys.stdout if json_output else sys.stderr)
        raise SystemExit(ExitCode.UNKNOWN) from None
    except KeyboardInterrupt:
        raise SystemExit(ExitCode.CANCELLED) from None
    except SystemExit as exc:
        if exc.code == 0:
            return
        if json_output:
            print(
                json.dumps(
                    {
                        "version": 1,
                        "result": "failed",
                        "exit_code": exc.code,
                        "message": "Invalid command or failed precondition",
                    }
                )
            )
        raise
    if result is not None:
        print(json.dumps(result, ensure_ascii=False))
