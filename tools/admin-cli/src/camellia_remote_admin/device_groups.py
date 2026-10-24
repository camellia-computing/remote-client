import argparse
import json

from . import transport
from .batch_operations import (
    canonical_operation_id,
    canonical_uuid,
    check_batch_response,
    check_control_response,
    fail,
    operation_headers,
    require_unique,
    required_generation,
)
from .outcomes import (
    ExitCode,
    Mutation,
    add_options,
    control_mutations,
    read_page,
    run_mutations,
    split_targets,
)


def headers_with(token):
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


# ---------- Device Group APIs ----------


def list_groups(url, token, name=None, page_size=50):
    headers = headers_with(token)
    params = {"pageSize": page_size}
    if name:
        params["name"] = name
    data, current = [], 0
    while True:
        current += 1
        params["current"] = current
        r = transport.get(f"{url}/api/device-groups", headers=headers, params=params)
        res = read_page(r)
        rows = res["data"]
        data.extend(rows)
        total = res.get("total", 0)
        if len(rows) < page_size or current * page_size >= total:
            break
    return data


def get_group_by_name(url, token, name):
    groups = list_groups(url, token, name)
    for g in groups:
        if str(g.get("name")) == name:
            return g
    return None


def create_group(url, token, name, note=None, accessed_from=None, operation_id=None):
    payload = {"name": name}
    if note is not None:
        payload["note"] = note
    if accessed_from is not None:
        payload["allowed_incomings"] = accessed_from
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    request_document = {
        "operation": "device_group_create",
        "name": name,
        "note": note or "",
        "allowed_incomings": accessed_from or [],
        "strategy_name": "",
    }
    headers = operation_headers(token, operation_id)
    r = transport.post(f"{url}/api/device-groups", headers=headers, json=payload)
    return check_control_response(
        r,
        operation="device_group_create",
        operation_id=operation_id,
        request_document=request_document,
        requested={"groups": 1},
    )


def update_group(
    url,
    token,
    name,
    new_name=None,
    note=None,
    accessed_from=None,
    operation_id=None,
    *,
    target=None,
):
    g = target if target is not None else get_group_by_name(url, token, name)
    if not g:
        fail(f"Group '{name}' not found", ExitCode.NO_MATCH)
    guid = g.get("guid")
    payload = {}
    if new_name is not None:
        payload["name"] = new_name
    if note is not None:
        payload["note"] = note
    if accessed_from is not None:
        payload["allowed_incomings"] = accessed_from
    if not payload:
        fail("at least one update field is required", ExitCode.INVALID)
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    generation = required_generation(g.get("mutation_generation"))
    request_document = {
        "operation": "device_group_update",
        "group": canonical_uuid(guid, "device group GUID"),
        "data": payload,
        "expected_generation": generation,
    }
    headers = operation_headers(token, operation_id, generation)
    r = transport.patch(
        f"{url}/api/device-groups/{guid}", headers=headers, json=payload
    )
    return check_control_response(
        r,
        operation="device_group_update",
        operation_id=operation_id,
        request_document=request_document,
        requested={"groups": 1},
    )


def delete_group_target(url, token, group, operation_id=None):
    guid = canonical_uuid(group.get("guid"), "device group GUID")
    generation = required_generation(group.get("mutation_generation"))
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    response = transport.delete(
        f"{url}/api/device-groups/{guid}",
        headers=operation_headers(token, operation_id, generation),
        json={},
    )
    return check_control_response(
        response,
        operation="device_group_delete",
        operation_id=operation_id,
        request_document={
            "operation": "device_group_delete",
            "group": guid,
            "expected_generation": generation,
        },
        requested={"groups": 1},
    )


# ---------- Device group assign APIs (name -> guid) ----------


def view_devices(
    url,
    token,
    group_name=None,
    id=None,
    device_name=None,
    user_name=None,
    device_username=None,
    page_size=50,
):
    """View devices in a device group with filters"""
    headers = headers_with(token)

    # Separate exact match and fuzzy match params
    params = {}
    fuzzy_params = {
        "id": id,
        "device_name": device_name,
        "user_name": user_name,
        "device_username": device_username,
    }

    # Add device_group_name without wildcard (exact match)
    if group_name:
        params["device_group_name"] = group_name

    # Add wildcard for fuzzy search to other params
    for k, v in fuzzy_params.items():
        if v is not None:
            params[k] = v

    params["pageSize"] = page_size

    data, current = [], 0
    while True:
        current += 1
        params["current"] = current
        r = transport.get(f"{url}/api/devices", headers=headers, params=params)
        res = read_page(r)
        rows = res["data"]
        data.extend(rows)
        total = res.get("total", 0)
        if len(rows) < page_size or current * page_size >= total:
            break
    return data


def add_devices(url, token, group_name, device_ids, operation_id=None, *, target=None):
    if not device_ids:
        fail("Mutation matched no devices", ExitCode.NO_MATCH)
    g = target if target is not None else get_group_by_name(url, token, group_name)
    if not g:
        fail(f"Group '{group_name}' not found", ExitCode.NO_MATCH)
    guid = canonical_uuid(g.get("guid"), "device group GUID")
    generation = required_generation(g.get("mutation_generation"))
    payload = device_ids if isinstance(device_ids, list) else [device_ids]
    require_unique(payload, "device")
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    request_document = {
        "operation": "device_group_add_devices",
        "group": guid,
        "devices": payload,
        "expected_generation": generation,
    }
    requested = {"devices": len(payload)}
    headers = operation_headers(token, operation_id, generation)
    r = transport.post(f"{url}/api/device-groups/{guid}", headers=headers, json=payload)
    return check_batch_response(
        r,
        operation="device_group_add_devices",
        operation_id=operation_id,
        request_document=request_document,
        requested=requested,
    )


def remove_devices(
    url, token, group_name, device_ids, operation_id=None, *, target=None
):
    if not device_ids:
        fail("Mutation matched no devices", ExitCode.NO_MATCH)
    g = target if target is not None else get_group_by_name(url, token, group_name)
    if not g:
        fail(f"Group '{group_name}' not found", ExitCode.NO_MATCH)
    guid = canonical_uuid(g.get("guid"), "device group GUID")
    generation = required_generation(g.get("mutation_generation"))
    payload = device_ids if isinstance(device_ids, list) else [device_ids]
    require_unique(payload, "device")
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    request_document = {
        "operation": "device_group_remove_devices",
        "group": guid,
        "devices": payload,
        "expected_generation": generation,
    }
    requested = {"devices": len(payload)}
    headers = operation_headers(token, operation_id, generation)
    r = transport.delete(
        f"{url}/api/device-groups/{guid}/devices", headers=headers, json=payload
    )
    return check_batch_response(
        r,
        operation="device_group_remove_devices",
        operation_id=operation_id,
        request_document=request_document,
        requested=requested,
    )


def parse_rules(value):
    if value is None:
        return None
    try:
        rules = json.loads(value)
    except ValueError:
        fail("--accessed-from must be a JSON array", ExitCode.INVALID)
    if not isinstance(rules, list):
        fail("--accessed-from must be a JSON array", ExitCode.INVALID)
    return rules


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="camellia-remote-admin device-groups", description="Device Group manager"
    )
    parser.add_argument(
        "command",
        choices=[
            "view",
            "add",
            "update",
            "delete",
            "view-devices",
            "add-devices",
            "remove-devices",
        ],
    )
    parser.add_argument("--url", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--name")
    parser.add_argument("--new-name")
    parser.add_argument("--note")
    parser.add_argument("--accessed-from")
    parser.add_argument("--ids")
    parser.add_argument("--operation-id")
    parser.add_argument("--id")
    parser.add_argument("--device-name")
    parser.add_argument("--user-name")
    parser.add_argument("--device-username")
    add_options(parser)
    args = parser.parse_args(argv)
    transport.configure(args)
    args.url = args.url.rstrip("/")
    operation_id = (
        canonical_operation_id(args.operation_id) if args.operation_id else None
    )
    if args.command == "view":
        return list_groups(args.url, args.token, args.name)
    if args.command == "view-devices":
        return view_devices(
            args.url,
            args.token,
            args.name,
            args.id,
            args.device_name,
            args.user_name,
            args.device_username,
        )
    rules = parse_rules(args.accessed_from)
    if args.command == "add":
        if not args.name:
            parser.error("--name is required")
        mutation = Mutation(
            {"groups": [args.name]},
            lambda key: create_group(
                args.url, args.token, args.name, args.note, rules, operation_id=key
            ),
        )
        if operation_id:
            mutation.operation_id = operation_id
        return run_mutations("device_group_create", [mutation], yes=True)
    if args.command == "delete":
        names = split_targets(args.name, "group names")
        rows = []
        for name in names:
            group = get_group_by_name(args.url, args.token, name)
            if not group:
                fail("Group not found", ExitCode.NO_MATCH)
            canonical_uuid(group.get("guid"), "group GUID")
            rows.append(group)
        mutations = control_mutations(
            rows,
            "groups",
            lambda row, key: delete_group_target(args.url, args.token, row, key),
            operation_id=operation_id,
        )
    elif args.command == "update":
        if not args.name:
            parser.error("--name is required")
        if args.new_name is None and args.note is None and rules is None:
            parser.error("At least one update field is required")
        group = get_group_by_name(args.url, args.token, args.name)
        if not group:
            fail("Group not found", ExitCode.NO_MATCH)
        mutations = control_mutations(
            [group],
            "groups",
            lambda row, key: update_group(
                args.url,
                args.token,
                args.name,
                args.new_name,
                args.note,
                rules,
                key,
                target=row,
            ),
            operation_id=operation_id,
        )
    else:
        ids = split_targets(args.ids, "device IDs")
        mutations = []
        if ids:
            if not args.name:
                parser.error("--name is required")
            group = get_group_by_name(args.url, args.token, args.name)
            if not group:
                fail("Group not found", ExitCode.NO_MATCH)
            guid = canonical_uuid(group.get("guid"), "group GUID")
            generation = required_generation(group.get("mutation_generation"))
            action = add_devices if args.command == "add-devices" else remove_devices
            mutation = Mutation(
                {"devices": ids},
                lambda key: action(
                    args.url, args.token, args.name, ids, operation_id=key, target=group
                ),
                generations={"groups": {guid: generation}},
            )
            if operation_id:
                mutation.operation_id = operation_id
            mutations.append(mutation)
    return run_mutations(
        "device_groups_" + args.command,
        mutations,
        allow_empty=args.allow_empty,
        yes=args.yes,
    )
