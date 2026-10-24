#!/usr/bin/env python3

import argparse

import requests
from admin_cli import (
    Mutation,
    add_options,
    control_mutations,
    entry,
    read_page,
    run_mutations,
)
from batch_operations import (
    canonical_model_pk,
    canonical_operation_id,
    check_batch_response,
    check_control_response,
    document_digest,
    fail,
    operation_headers,
    require_unique,
    required_generation,
)


def view(
    url,
    token,
    name=None,
    group_name=None,
):
    headers = {"Authorization": f"Bearer {token}"}
    pageSize = 30
    params = {
        "name": name,
        "group_name": group_name,
    }

    # Exact filters stay exact; wildcard modes must be explicitly requested.
    params = {key: value for key, value in params.items() if value is not None}
    params["pageSize"] = pageSize

    users = []

    current = 0

    while True:
        current += 1
        params["current"] = current
        response = requests.get(f"{url}/api/users", headers=headers, params=params)
        response_json = read_page(response)
        data = response_json["data"]
        users.extend(data)

        total = response_json.get("total", 0)
        if len(data) < pageSize or current * pageSize >= total:
            break

    return users


def _control_mutation(
    url,
    token,
    guid,
    *,
    action,
    operation_id=None,
    expected_generation=None,
):
    guid = canonical_model_pk(guid, "user GUID")
    expected_generation = required_generation(expected_generation)
    operation = f"user_status_{action}"
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation target: user {guid}", flush=True)
    print(f"Operation ID: {operation_id}", flush=True)
    request_document = {"operation": operation, "user": str(guid)}
    if expected_generation is not None:
        request_document["expected_generation"] = expected_generation
    response = requests.post(
        f"{url}/api/users/{guid}/{action}",
        headers=operation_headers(token, operation_id, expected_generation),
        json={},
    )
    return check_control_response(
        response,
        operation=operation,
        operation_id=operation_id,
        request_document=request_document,
        requested={"users": 1},
    )


def disable(url, token, guid, name, operation_id=None, expected_generation=None):
    print("Disable", name)
    return _control_mutation(
        url,
        token,
        guid,
        action="disable",
        operation_id=operation_id,
        expected_generation=expected_generation,
    )


def enable(url, token, guid, name, operation_id=None, expected_generation=None):
    print("Enable", name)
    return _control_mutation(
        url,
        token,
        guid,
        action="enable",
        operation_id=operation_id,
        expected_generation=expected_generation,
    )


def delete_user(url, token, guid, name, operation_id=None, expected_generation=None):
    print("Delete", name)
    guid = canonical_model_pk(guid, "user GUID")
    expected_generation = required_generation(expected_generation)
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation target: user {guid}", flush=True)
    print(f"Operation ID: {operation_id}", flush=True)
    response = requests.delete(
        f"{url}/api/users/{guid}",
        headers=operation_headers(token, operation_id, expected_generation),
        json={},
    )
    return check_control_response(
        response,
        operation="user_delete",
        operation_id=operation_id,
        request_document={
            "operation": "user_delete",
            "user": guid,
            **(
                {"expected_generation": expected_generation}
                if expected_generation is not None
                else {}
            ),
        },
        requested={"users": 1},
    )


def new_user(
    url,
    token,
    name,
    password,
    group_name=None,
    email=None,
    note=None,
    operation_id=None,
):
    """Create a new user"""
    payload = {
        "name": name,
        "password": password,
    }
    if group_name is not None:
        payload["group_name"] = group_name
    if email is not None:
        payload["email"] = email
    if note is not None:
        payload["note"] = note
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    response = requests.post(
        f"{url}/api/users",
        headers=operation_headers(token, operation_id),
        json=payload,
    )
    return check_control_response(
        response,
        operation="user_create",
        operation_id=operation_id,
        request_document={
            "operation": "user_create",
            "username": name,
            "password_digest": document_digest(password),
            "email": email or "",
            "note": note or "",
            "group_name": group_name or "",
        },
        requested={"users": 1},
    )


def force_logout(url, token, user_guids, operation_id=None):
    """Force logout users"""
    user_guids = user_guids if isinstance(user_guids, list) else [user_guids]
    if not user_guids:
        fail("Mutation matched no users", 3)
    require_unique(user_guids, "user")
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    headers = operation_headers(token, operation_id)
    payload = {
        "user_guids": user_guids,
    }
    request_document = {
        "operation": "users_force_logout",
        "users": user_guids,
    }
    requested = {"users": len(user_guids)}
    response = requests.post(
        f"{url}/api/users/force-logout", headers=headers, json=payload
    )
    return check_batch_response(
        response,
        operation="users_force_logout",
        operation_id=operation_id,
        request_document=request_document,
        requested=requested,
    )


def main():
    parser = argparse.ArgumentParser(description="User manager")
    parser.add_argument(
        "command",
        choices=["view", "disable", "enable", "delete", "new", "force-logout"],
    )
    parser.add_argument("--url", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--name")
    parser.add_argument("--guid", help="Exact Management user GUID")
    parser.add_argument("--group_name")
    parser.add_argument("--password")
    parser.add_argument("--email")
    parser.add_argument("--note")
    parser.add_argument("--operation-id")
    parser.add_argument("--expected-generation", type=int)
    add_options(parser)
    args = parser.parse_args()
    args.url = args.url.rstrip("/")
    operation_id = (
        canonical_operation_id(args.operation_id) if args.operation_id else None
    )
    if args.command == "new":
        if not args.name or not args.password:
            parser.error("--name and --password are required for new")
        mutation = Mutation(
            {"users": [args.name]},
            lambda key: new_user(
                args.url,
                args.token,
                args.name,
                args.password,
                args.group_name,
                args.email,
                args.note,
                operation_id=key,
            ),
        )
        if operation_id:
            mutation.operation_id = operation_id
        return run_mutations("user_create", [mutation], yes=True)

    if args.guid:
        if args.command == "view":
            parser.error("--guid is only supported for mutations")
        rows = [
            {
                "guid": canonical_model_pk(args.guid, "user GUID"),
                "name": args.name or args.guid,
                "mutation_generation": args.expected_generation,
            }
        ]
    else:
        rows = view(args.url, args.token, args.name, args.group_name)
    if args.command == "view":
        return rows

    for row in rows:
        canonical_model_pk(row.get("guid"), "user GUID")
    if args.expected_generation is not None and args.command != "force-logout":
        if len(rows) != 1:
            parser.error("--expected-generation requires exactly one user")
        rows = [{**rows[0], "mutation_generation": args.expected_generation}]
    if args.command == "force-logout":
        mutations = []
        if rows:
            mutation = Mutation(
                {"users": [row["guid"] for row in rows]},
                lambda key: force_logout(
                    args.url,
                    args.token,
                    [row["guid"] for row in rows],
                    operation_id=key,
                ),
            )
            if operation_id:
                mutation.operation_id = operation_id
            mutations.append(mutation)
    else:
        action = {"disable": disable, "enable": enable, "delete": delete_user}[
            args.command
        ]
        mutations = control_mutations(
            rows,
            "users",
            lambda row, key: action(
                args.url,
                args.token,
                row["guid"],
                row["name"],
                operation_id=key,
                expected_generation=row["mutation_generation"],
            ),
            operation_id=operation_id,
        )
    return run_mutations(
        "users_" + args.command, mutations, allow_empty=args.allow_empty, yes=args.yes
    )


if __name__ == "__main__":
    entry(main)
