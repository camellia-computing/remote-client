#!/usr/bin/env python3

import argparse
import json

import cli_transport as transport
from admin_cli import (
    ExitCode,
    Mutation,
    add_options,
    control_mutations,
    entry,
    read_page,
    run_mutations,
    split_targets,
)
from admin_cli import read_json as check_response
from batch_operations import (
    canonical_model_pk,
    canonical_operation_id,
    canonical_uuid,
    check_batch_response,
    check_control_response,
    document_digest,
    fail,
    operation_headers,
    require_unique,
    required_generation,
)


def headers_with(token):
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


# ---------- Strategies APIs ----------


def list_strategies(url, token):
    """List all strategies"""
    headers = headers_with(token)
    r = transport.get(f"{url}/api/strategies", headers=headers)
    body = check_response(r)
    if not isinstance(body, list) or any(not isinstance(row, dict) for row in body):
        fail("Management strategies inventory is malformed")
    return body


def get_strategy_by_guid(url, token, guid):
    """Get strategy by GUID"""
    headers = headers_with(token)
    r = transport.get(f"{url}/api/strategies/{guid}", headers=headers)
    return check_response(r)


def get_strategy_by_name(url, token, name):
    """Get strategy by name"""
    strategies = list_strategies(url, token)
    if not strategies:
        return None
    for s in strategies:
        if str(s.get("name")) == name:
            return s
    return None


def set_strategy_status(url, token, name, enabled, operation_id=None, *, target=None):
    """Set a strategy status with replay and optimistic concurrency."""

    if type(enabled) is not bool:
        fail("strategy status must be boolean")
    strategy = target if target is not None else get_strategy_by_name(url, token, name)
    if not strategy:
        fail(f"Strategy '{name}' not found", ExitCode.NO_MATCH)
    guid = canonical_uuid(strategy.get("guid"), "strategy GUID")
    generation = required_generation(strategy.get("mutation_generation"))
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    headers = operation_headers(token, operation_id, generation)
    request_document = {
        "operation": "strategy_status",
        "strategy": guid,
        "enabled": enabled,
        "expected_generation": generation,
    }
    response = transport.put(
        f"{url}/api/strategies/{guid}/status", headers=headers, json=enabled
    )
    return check_control_response(
        response,
        operation="strategy_status",
        operation_id=operation_id,
        request_document=request_document,
        requested={"strategies": 1},
    )


def enable_strategy(url, token, name, operation_id=None):
    """Enable a strategy"""
    return set_strategy_status(url, token, name, True, operation_id=operation_id)


def disable_strategy(url, token, name, operation_id=None):
    """Disable a strategy"""
    return set_strategy_status(url, token, name, False, operation_id=operation_id)


def create_strategy(
    url, token, name, config_options=None, enabled=True, operation_id=None
):
    payload = {"name": name, "config_options": config_options or {}, "enabled": enabled}
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    response = transport.post(
        f"{url}/api/strategies",
        headers=operation_headers(token, operation_id),
        json=payload,
    )
    return check_control_response(
        response,
        operation="strategy_create",
        operation_id=operation_id,
        request_document={"operation": "strategy_create", **payload},
        requested={"strategies": 1},
    )


def update_strategy(
    url,
    token,
    name,
    *,
    new_name=None,
    config_options=None,
    enabled=None,
    operation_id=None,
    target=None,
):
    strategy = target if target is not None else get_strategy_by_name(url, token, name)
    if not strategy:
        fail(f"Strategy '{name}' not found", ExitCode.NO_MATCH)
    guid = canonical_uuid(strategy.get("guid"), "strategy GUID")
    generation = required_generation(strategy.get("mutation_generation"))
    payload = {}
    if new_name is not None:
        payload["name"] = new_name
    if config_options is not None:
        payload["config_options"] = config_options
    if enabled is not None:
        payload["enabled"] = enabled
    if not payload:
        fail("at least one update field is required", ExitCode.INVALID)
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    response = transport.patch(
        f"{url}/api/strategies/{guid}",
        headers=operation_headers(token, operation_id, generation),
        json=payload,
    )
    return check_control_response(
        response,
        operation="strategy_update",
        operation_id=operation_id,
        request_document={
            "operation": "strategy_update",
            "strategy": guid,
            "data": payload,
            "expected_generation": generation,
        },
        requested={"strategies": 1},
    )


def delete_strategy(url, token, name, operation_id=None, *, target=None):
    strategy = target if target is not None else get_strategy_by_name(url, token, name)
    if not strategy:
        fail(f"Strategy '{name}' not found", ExitCode.NO_MATCH)
    guid = canonical_uuid(strategy.get("guid"), "strategy GUID")
    generation = required_generation(strategy.get("mutation_generation"))
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    response = transport.delete(
        f"{url}/api/strategies/{guid}",
        headers=operation_headers(token, operation_id, generation),
        json={},
    )
    return check_control_response(
        response,
        operation="strategy_delete",
        operation_id=operation_id,
        request_document={
            "operation": "strategy_delete",
            "strategy": guid,
            "expected_generation": generation,
        },
        requested={"strategies": 1},
    )


def _inventory_target(url, token, identifier, endpoint, field, guid_parser):
    """Never guess whether an all-numeric RID/name is a database primary key."""
    if not isinstance(identifier, str) or not identifier:
        fail("Target selector is empty", ExitCode.INVALID)
    is_guid = identifier.startswith("guid:")
    if is_guid:
        identifier = guid_parser(identifier[5:], "target GUID")
    elif identifier.startswith(field + ":"):
        identifier = identifier[len(field) + 1 :]
    params = {"pageSize": 2, "guid" if is_guid else field: identifier}
    response = transport.get(
        f"{url}/api/{endpoint}", headers=headers_with(token), params=params
    )
    page = read_page(response)
    key = "guid" if is_guid else field
    matches = [row for row in page["data"] if str(row.get(key)) == identifier]
    if len(matches) > 1:
        fail("Target selector is ambiguous", ExitCode.INVALID)
    return matches[0] if matches else None


def get_device_target(url, token, identifier):
    return _inventory_target(
        url, token, identifier, "devices", "id", canonical_model_pk
    )


def get_user_target(url, token, identifier):
    return _inventory_target(
        url, token, identifier, "users", "name", canonical_model_pk
    )


def get_device_group_target(url, token, identifier):
    return _inventory_target(
        url, token, identifier, "device-groups", "name", canonical_uuid
    )


def prepare_assignment(
    url, token, strategy_name, peers=None, users=None, device_groups=None
):
    """
    Assign strategy to peers, users, or device groups

    Args:
        strategy_name: Name of the strategy (or None to unassign)
        peers: List of device IDs or GUIDs
        users: List of user names or GUIDs
        device_groups: List of device group names or GUIDs
    """
    if not peers and not users and not device_groups:
        fail("Mutation matched no targets", ExitCode.NO_MATCH)
    # Get strategy GUID if strategy_name is provided
    strategy_guid = None
    if strategy_name:
        strategy = get_strategy_by_name(url, token, strategy_name)
        if not strategy:
            fail("Strategy not found", ExitCode.NO_MATCH)
        strategy_guid = canonical_uuid(strategy.get("guid"), "strategy GUID")

    # Resolve exact target rows so the batch is bound to one inventory snapshot.
    peer_guids = []
    peer_generations = {}
    if peers:
        for peer in peers:
            target = get_device_target(url, token, peer)
            if not target:
                fail("Device not found", ExitCode.NO_MATCH)
            guid = canonical_model_pk(target.get("guid"), "device GUID")
            peer_guids.append(guid)
            peer_generations[guid] = required_generation(
                target.get("mutation_generation")
            )

    user_guids = []
    user_generations = {}
    if users:
        for user in users:
            target = get_user_target(url, token, user)
            if not target:
                fail("User not found", ExitCode.NO_MATCH)
            guid = canonical_model_pk(target.get("guid"), "user GUID")
            user_guids.append(guid)
            user_generations[guid] = required_generation(
                target.get("mutation_generation")
            )

    device_group_guids = []
    device_group_generations = {}
    if device_groups:
        for dg in device_groups:
            target = get_device_group_target(url, token, dg)
            if not target:
                fail("Device group not found", ExitCode.NO_MATCH)
            guid = canonical_uuid(target.get("guid"), "device group GUID")
            device_group_guids.append(guid)
            device_group_generations[guid] = required_generation(
                target.get("mutation_generation")
            )

    require_unique(peer_guids, "device")
    require_unique(user_guids, "user")
    require_unique(device_group_guids, "device group")

    # Build payload
    payload = {}
    if strategy_guid:
        payload["strategy"] = strategy_guid

    payload["peers"] = peer_guids
    payload["users"] = user_guids
    payload["groups"] = device_group_guids
    expected_generations = {
        "devices": peer_generations,
        "users": user_generations,
        "groups": device_group_generations,
    }
    payload["expected_generations"] = expected_generations

    request_document = {
        "operation": "strategy_assign",
        "strategy": strategy_guid,
        "peers": peer_guids,
        "users": user_guids,
        "groups": device_group_guids,
        "expected_generations": expected_generations,
    }
    requested = {
        "devices": len(peer_guids),
        "users": len(user_guids),
        "groups": len(device_group_guids),
    }
    return payload, request_document, requested


def assign_strategy(
    url,
    token,
    strategy_name,
    peers=None,
    users=None,
    device_groups=None,
    operation_id=None,
    *,
    prepared=None,
):
    payload, request_document, requested = (
        prepared
        if prepared is not None
        else prepare_assignment(url, token, strategy_name, peers, users, device_groups)
    )
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    print(f"Target snapshot digest: {document_digest(request_document)}", flush=True)
    headers = operation_headers(token, operation_id)
    r = transport.post(f"{url}/api/strategies/assign", headers=headers, json=payload)
    return check_batch_response(
        r,
        operation="strategy_assign",
        operation_id=operation_id,
        request_document=request_document,
        requested=requested,
    )


def main():
    parser = argparse.ArgumentParser(description="Strategy manager")
    parser.add_argument(
        "command",
        choices=[
            "list",
            "view",
            "add",
            "update",
            "delete",
            "enable",
            "disable",
            "assign",
            "unassign",
        ],
    )
    parser.add_argument("--url", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--name")
    parser.add_argument("--guid")
    parser.add_argument("--new-name")
    parser.add_argument("--config-options")
    parser.add_argument("--enabled", choices=("true", "false"))
    parser.add_argument("--peers")
    parser.add_argument("--users")
    parser.add_argument("--device-groups")
    parser.add_argument("--operation-id")
    add_options(parser)
    args = parser.parse_args()
    transport.configure(args)
    args.url = args.url.rstrip("/")
    operation_id = (
        canonical_operation_id(args.operation_id) if args.operation_id else None
    )
    if args.command == "list":
        return list_strategies(args.url, args.token)
    if args.command == "view":
        if args.guid:
            return get_strategy_by_guid(
                args.url, args.token, canonical_uuid(args.guid, "strategy GUID")
            )
        if not args.name:
            parser.error("--name or --guid is required")
        strategy = get_strategy_by_name(args.url, args.token, args.name)
        if not strategy:
            fail("Strategy not found", ExitCode.NO_MATCH)
        return get_strategy_by_guid(args.url, args.token, strategy["guid"])
    try:
        config = (
            json.loads(args.config_options) if args.config_options is not None else None
        )
    except ValueError:
        parser.error("--config-options must be a JSON object")
    if args.config_options is not None and not isinstance(config, dict):
        parser.error("--config-options must be a JSON object")
    enabled = args.enabled == "true" if args.enabled is not None else None
    if args.command in ("assign", "unassign"):
        if args.command == "assign" and not args.name:
            parser.error("--name is required")
        peers = split_targets(args.peers, "device targets")
        users = split_targets(args.users, "user targets")
        groups = split_targets(args.device_groups, "group targets")
        mutations = []
        if peers or users or groups:
            name = args.name if args.command == "assign" else None
            prepared = prepare_assignment(
                args.url, args.token, name, peers, users, groups
            )
            payload, _, _ = prepared
            mutations = [
                Mutation(
                    {
                        "devices": payload["peers"],
                        "users": payload["users"],
                        "groups": payload["groups"],
                    },
                    lambda key: assign_strategy(
                        args.url, args.token, name, operation_id=key, prepared=prepared
                    ),
                    generations=payload["expected_generations"],
                )
            ]
    else:
        if not args.name:
            parser.error("--name is required")
        if args.command == "add":
            mutations = [
                Mutation(
                    {"strategies": [args.name]},
                    lambda key: create_strategy(
                        args.url,
                        args.token,
                        args.name,
                        config,
                        True if enabled is None else enabled,
                        key,
                    ),
                )
            ]
        else:
            if (
                args.command == "update"
                and args.new_name is None
                and config is None
                and enabled is None
            ):
                parser.error("At least one update field is required")
            strategy = get_strategy_by_name(args.url, args.token, args.name)
            if not strategy:
                fail("Strategy not found", ExitCode.NO_MATCH)
            canonical_uuid(strategy.get("guid"), "strategy GUID")

            def mutate(row, key):
                if args.command == "update":
                    return update_strategy(
                        args.url,
                        args.token,
                        args.name,
                        new_name=args.new_name,
                        config_options=config,
                        enabled=enabled,
                        operation_id=key,
                        target=row,
                    )
                if args.command == "delete":
                    return delete_strategy(
                        args.url, args.token, args.name, key, target=row
                    )
                return set_strategy_status(
                    args.url,
                    args.token,
                    args.name,
                    args.command == "enable",
                    key,
                    target=row,
                )

            mutations = control_mutations([strategy], "strategies", mutate)
    if operation_id:
        if len(mutations) != 1:
            fail("--operation-id requires exactly one operation", ExitCode.INVALID)
        mutations[0].operation_id = operation_id
    return run_mutations(
        "strategies_" + args.command,
        mutations,
        allow_empty=args.allow_empty,
        yes=args.yes,
    )


if __name__ == "__main__":
    entry(main)
