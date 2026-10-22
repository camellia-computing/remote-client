#!/usr/bin/env python3

import argparse
import json

import requests
from batch_operations import (
    canonical_model_pk,
    canonical_operation_id,
    canonical_uuid,
    check_batch_response,
    check_control_response,
    fail,
    operation_headers,
    required_generation,
    require_unique,
)


def check_response(response):
    """
    Check API response and handle errors.

    Two error cases:
    1. Status code is not 200 -> exit with error
    2. Response contains {"error": "xxx"} -> exit with error
    """
    if response.status_code != 200:
        print(f"Error: HTTP {response.status_code}: {response.text}")
        exit(1)

    # Check for {"error": "xxx"} in response
    if response.text and response.text.strip():
        try:
            json_data = response.json()
            if isinstance(json_data, dict) and "error" in json_data:
                print(f"Error: {json_data['error']}")
                exit(1)
            return json_data
        except ValueError:
            return response.text

    return None


def headers_with(token):
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


# ---------- Strategies APIs ----------

def list_strategies(url, token):
    """List all strategies"""
    headers = headers_with(token)
    r = requests.get(f"{url}/api/strategies", headers=headers)
    return check_response(r)


def get_strategy_by_guid(url, token, guid):
    """Get strategy by GUID"""
    headers = headers_with(token)
    r = requests.get(f"{url}/api/strategies/{guid}", headers=headers)
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


def set_strategy_status(url, token, name, enabled, operation_id=None):
    """Set a strategy status with replay and optimistic concurrency."""

    if type(enabled) is not bool:
        fail("strategy status must be boolean")
    strategy = get_strategy_by_name(url, token, name)
    if not strategy:
        fail(f"Strategy '{name}' not found")
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
    response = requests.put(
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


def create_strategy(url, token, name, config_options=None, enabled=True, operation_id=None):
    payload = {"name": name, "config_options": config_options or {}, "enabled": enabled}
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    response = requests.post(
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
):
    strategy = get_strategy_by_name(url, token, name)
    if not strategy:
        fail(f"Strategy '{name}' not found")
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
        fail("at least one update field is required")
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    response = requests.patch(
        f"{url}/api/strategies/{guid}",
        headers=operation_headers(
            token, operation_id, generation
        ),
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


def delete_strategy(url, token, name, operation_id=None):
    strategy = get_strategy_by_name(url, token, name)
    if not strategy:
        fail(f"Strategy '{name}' not found")
    guid = canonical_uuid(strategy.get("guid"), "strategy GUID")
    generation = required_generation(strategy.get("mutation_generation"))
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    response = requests.delete(
        f"{url}/api/strategies/{guid}",
        headers=operation_headers(
            token, operation_id, generation
        ),
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


def get_device_target(url, token, device_identifier):
    """Resolve one exact device row, including its mutation generation."""

    headers = headers_with(token)
    is_guid = (
        isinstance(device_identifier, str)
        and device_identifier.isascii()
        and device_identifier.isdigit()
        and not device_identifier.startswith("0")
    )
    params = {
        "guid" if is_guid else "id": device_identifier,
        "pageSize": 2,
    }
    r = requests.get(f"{url}/api/devices", headers=headers, params=params)
    res = check_response(r)
    if not res:
        return None

    devices_data = res.get("data", []) if isinstance(res, dict) else res
    for d in devices_data:
        field = "guid" if is_guid else "id"
        if str(d.get(field)) == device_identifier:
            return d
    return None


def get_user_target(url, token, user_identifier):
    """Resolve one exact user row, including its mutation generation."""

    headers = headers_with(token)
    is_guid = (
        isinstance(user_identifier, str)
        and user_identifier.isascii()
        and user_identifier.isdigit()
        and not user_identifier.startswith("0")
    )
    params = {
        "guid" if is_guid else "name": user_identifier,
        "pageSize": 2,
    }
    r = requests.get(f"{url}/api/users", headers=headers, params=params)
    res = check_response(r)
    if not res:
        return None

    users_data = res.get("data", []) if isinstance(res, dict) else res
    for u in users_data:
        field = "guid" if is_guid else "name"
        if str(u.get(field)) == user_identifier:
            return u
    return None


def get_device_group_target(url, token, group_identifier):
    """Resolve one exact device-group row, including its mutation generation."""

    headers = headers_with(token)
    is_guid = (
        isinstance(group_identifier, str)
        and len(group_identifier) == 36
        and group_identifier.count("-") == 4
    )
    if is_guid:
        group_identifier = canonical_uuid(group_identifier, "device group GUID")
    params = {
        "pageSize": 2,
        "guid" if is_guid else "name": group_identifier,
    }
    r = requests.get(f"{url}/api/device-groups", headers=headers, params=params)
    res = check_response(r)
    if not res:
        return None

    groups_data = res.get("data", []) if isinstance(res, dict) else res
    for g in groups_data:
        field = "guid" if is_guid else "name"
        if str(g.get(field)) == group_identifier:
            return g
    return None


def assign_strategy(url, token, strategy_name, peers=None, users=None, device_groups=None, operation_id=None):
    """
    Assign strategy to peers, users, or device groups

    Args:
        strategy_name: Name of the strategy (or None to unassign)
        peers: List of device IDs or GUIDs
        users: List of user names or GUIDs
        device_groups: List of device group names or GUIDs
    """
    # Get strategy GUID if strategy_name is provided
    strategy_guid = None
    if strategy_name:
        strategy = get_strategy_by_name(url, token, strategy_name)
        if not strategy:
            print(f"Error: Strategy '{strategy_name}' not found")
            exit(1)
        strategy_guid = canonical_uuid(strategy.get("guid"), "strategy GUID")

    # Resolve exact target rows so the batch is bound to one inventory snapshot.
    peer_guids = []
    peer_generations = {}
    if peers:
        for peer in peers:
            target = get_device_target(url, token, peer)
            if not target:
                fail(f"Device '{peer}' not found")
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
                fail(f"User '{user}' not found")
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
                fail(f"Device group '{dg}' not found")
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

    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
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
    headers = operation_headers(token, operation_id)
    r = requests.post(f"{url}/api/strategies/assign", headers=headers, json=payload)
    return check_batch_response(
        r,
        operation="strategy_assign",
        operation_id=operation_id,
        request_document=request_document,
        requested=requested,
    )


def main():
    parser = argparse.ArgumentParser(description="Strategy manager")
    parser.add_argument("command", choices=[
        "list", "view", "add", "update", "delete", "enable", "disable", "assign", "unassign"
    ])
    parser.add_argument("--url", required=True, help="Server URL")
    parser.add_argument("--token", required=True, help="API token")

    parser.add_argument("--name", help="Strategy name (for view/enable/disable/assign commands)")
    parser.add_argument("--guid", help="Strategy GUID (for view command, alternative to --name)")
    parser.add_argument("--new-name", help="New strategy name (for update)")
    parser.add_argument("--config-options", help="JSON object of managed strategy options")
    parser.add_argument("--enabled", choices=("true", "false"), help="Strategy enabled state")

    # For assign/unassign commands
    parser.add_argument("--peers", help="Comma separated device IDs or GUIDs (requires Device Permission:r)")
    parser.add_argument("--users", help="Comma separated user names or GUIDs (requires User Permission:r)")
    parser.add_argument("--device-groups", help="Comma separated device group names or GUIDs (requires Device Group Permission:r)")
    parser.add_argument("--operation-id", help="Canonical UUID used to retry one mutation after response loss")

    args = parser.parse_args()
    while args.url.endswith("/"): args.url = args.url[:-1]

    if args.command == "list":
        res = list_strategies(args.url, args.token)
        print(json.dumps(res, indent=2))

    elif args.command == "view":
        if args.guid:
            res = get_strategy_by_guid(args.url, args.token, args.guid)
            print(json.dumps(res, indent=2))
        elif args.name:
            strategy = get_strategy_by_name(args.url, args.token, args.name)
            if not strategy:
                print(f"Error: Strategy '{args.name}' not found")
                exit(1)
            # Get full details by GUID
            guid = strategy.get("guid")
            res = get_strategy_by_guid(args.url, args.token, guid)
            print(json.dumps(res, indent=2))
        else:
            print("Error: --name or --guid is required for view command")
            exit(1)

    elif args.command in ("add", "update", "delete"):
        if not args.name:
            fail("--name is required")
        try:
            config_options = json.loads(args.config_options) if args.config_options is not None else None
        except ValueError:
            fail("--config-options must be a JSON object")
        if config_options is not None and not isinstance(config_options, dict):
            fail("--config-options must be a JSON object")
        enabled = None if args.enabled is None else args.enabled == "true"
        if args.command == "add":
            print(
                create_strategy(
                    args.url,
                    args.token,
                    args.name,
                    config_options,
                    True if enabled is None else enabled,
                    operation_id=args.operation_id,
                )
            )
        elif args.command == "update":
            print(
                update_strategy(
                    args.url,
                    args.token,
                    args.name,
                    new_name=args.new_name,
                    config_options=config_options,
                    enabled=enabled,
                    operation_id=args.operation_id,
                )
            )
        else:
            print(delete_strategy(args.url, args.token, args.name, args.operation_id))

    elif args.command == "enable":
        if not args.name:
            print("Error: --name is required")
            exit(1)
        print(enable_strategy(args.url, args.token, args.name, args.operation_id))

    elif args.command == "disable":
        if not args.name:
            print("Error: --name is required")
            exit(1)
        print(disable_strategy(args.url, args.token, args.name, args.operation_id))

    elif args.command == "assign":
        if not args.name:
            print("Error: --name is required")
            exit(1)
        if not args.peers and not args.users and not args.device_groups:
            print("Error: at least one of --peers, --users, or --device-groups is required")
            exit(1)

        peers = [x.strip() for x in args.peers.split(",") if x.strip()] if args.peers else None
        users = [x.strip() for x in args.users.split(",") if x.strip()] if args.users else None
        device_groups = [x.strip() for x in args.device_groups.split(",") if x.strip()] if args.device_groups else None

        assign_strategy(
            args.url,
            args.token,
            args.name,
            peers=peers,
            users=users,
            device_groups=device_groups,
            operation_id=args.operation_id,
        )
        count = (len(peers) if peers else 0) + (len(users) if users else 0) + (len(device_groups) if device_groups else 0)
        print(f"Success: Assigned strategy '{args.name}' to {count} target(s)")

    elif args.command == "unassign":
        if not args.peers and not args.users and not args.device_groups:
            print("Error: at least one of --peers, --users, or --device-groups is required")
            exit(1)

        peers = [x.strip() for x in args.peers.split(",") if x.strip()] if args.peers else None
        users = [x.strip() for x in args.users.split(",") if x.strip()] if args.users else None
        device_groups = [x.strip() for x in args.device_groups.split(",") if x.strip()] if args.device_groups else None

        assign_strategy(
            args.url,
            args.token,
            None,
            peers=peers,
            users=users,
            device_groups=device_groups,
            operation_id=args.operation_id,
        )
        count = (len(peers) if peers else 0) + (len(users) if users else 0) + (len(device_groups) if device_groups else 0)
        print(f"Success: Unassigned strategy from {count} target(s)")


if __name__ == "__main__":
    main()
