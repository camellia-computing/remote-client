#!/usr/bin/env python3

import argparse
import sys

import requests
from batch_operations import (
    canonical_model_pk,
    canonical_operation_id,
    check_batch_response,
    check_control_response,
    fail,
    operation_headers,
    require_unique,
)


def check_response(response):
    """
    Check API response and handle errors properly.
    Exit with code 1 if there's an error.
    """
    if response.status_code != 200:
        print(f"Error: HTTP {response.status_code}: {response.text}")
        sys.exit(1)

    if response.text and response.text.strip():
        try:
            json_data = response.json()
            if isinstance(json_data, dict) and "error" in json_data:
                print(f"Error: {json_data['error']}")
                sys.exit(1)
            return json_data
        except ValueError:
            return response.text

    return None


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

    params = {
        k: "%" + v + "%" if (v != "-" and "%" not in v) else v
        for k, v in params.items()
        if v is not None
    }
    params["pageSize"] = pageSize

    users = []

    current = 0

    while True:
        current += 1
        params["current"] = current
        response = requests.get(f"{url}/api/users", headers=headers, params=params)
        if response.status_code != 200:
            print(f"Error: HTTP {response.status_code} - {response.text}")
            sys.exit(1)

        response_json = response.json()
        if "error" in response_json:
            print(f"Error: {response_json['error']}")
            sys.exit(1)

        data = response_json.get("data", [])
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
):
    guid = canonical_model_pk(guid, "user GUID")
    operation = f"user_status_{action}"
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation target: user {guid}", flush=True)
    print(f"Operation ID: {operation_id}", flush=True)
    request_document = {"operation": operation, "user": str(guid)}
    response = requests.post(
        f"{url}/api/users/{guid}/{action}",
        headers=operation_headers(token, operation_id),
        json={},
    )
    return check_control_response(
        response,
        operation=operation,
        operation_id=operation_id,
        request_document=request_document,
        requested={"users": 1},
    )


def disable(url, token, guid, name, operation_id=None):
    print("Disable", name)
    return _control_mutation(
        url,
        token,
        guid,
        action="disable",
        operation_id=operation_id,
    )


def enable(url, token, guid, name, operation_id=None):
    print("Enable", name)
    return _control_mutation(
        url,
        token,
        guid,
        action="enable",
        operation_id=operation_id,
    )


def delete_user(url, token, guid, name):
    print("Delete", name)
    headers = {"Authorization": f"Bearer {token}"}
    response = requests.delete(f"{url}/api/users/{guid}", headers=headers)
    check_response(response)


def new_user(url, token, name, password, group_name=None, email=None, note=None):
    """Create a new user"""
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    payload = {
        "name": name,
        "password": password,
    }
    if group_name:
        payload["group_name"] = group_name
    if email:
        payload["email"] = email
    if note:
        payload["note"] = note
    response = requests.post(f"{url}/api/users", headers=headers, json=payload)
    check_response(response)


def force_logout(url, token, user_guids, operation_id=None):
    """Force logout users"""
    user_guids = user_guids if isinstance(user_guids, list) else [user_guids]
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
        choices=[
            "view",
            "disable",
            "enable",
            "delete",
            "new",
            "force-logout",
        ],
        help="Command to execute",
    )
    parser.add_argument("--url", required=True, help="URL of the API")
    parser.add_argument(
        "--token", required=True, help="Bearer token for authentication"
    )
    parser.add_argument("--name", help="User name")
    parser.add_argument(
        "--guid",
        help="Exact Management user GUID for a control replay without a list lookup",
    )
    parser.add_argument(
        "--group_name",
        help="Group name (for filtering in view or for new command)",
    )
    parser.add_argument("--password", help="User password (for new command)")
    parser.add_argument("--email", help="User email (for new command)")
    parser.add_argument("--note", help="User note (for new command)")
    parser.add_argument(
        "--operation-id",
        help=(
            "Canonical UUID used to retry one control/batch mutation after "
            "response loss"
        ),
    )

    args = parser.parse_args()

    while args.url.endswith("/"):
        args.url = args.url[:-1]

    if args.command == "new":
        if not args.name or not args.password or not args.group_name:
            print(
                "Error: --name, --password and --group_name are required for "
                "new command"
            )
            sys.exit(1)
        new_user(
            args.url,
            args.token,
            args.name,
            args.password,
            args.group_name,
            args.email,
            args.note,
        )
        print("Success: User created")
        return

    if args.guid:
        if args.command not in ("disable", "enable", "force-logout"):
            fail(f"--guid is not supported for {args.command}")
        user_guid = canonical_model_pk(args.guid, "user GUID")
        users = [{"guid": user_guid, "name": args.name or user_guid}]
    else:
        users = view(
            args.url,
            args.token,
            args.name,
            args.group_name,
        )

    if args.command == "view":
        if len(users) == 0:
            print("Found 0 users")
        else:
            for user in users:
                print(user)
    elif args.command in [
        "disable",
        "enable",
        "delete",
        "force-logout",
    ]:
        if args.operation_id and args.command not in (
            "disable",
            "enable",
            "force-logout",
        ):
            fail(f"--operation-id is not supported for {args.command}")

        if len(users) == 0:
            print("Found 0 users")
            fail(f"{args.command} matched no users")
            return
        if args.operation_id and len(users) != 1 and args.command != "force-logout":
            fail("--operation-id requires exactly one matched user")

        # Check if we need user confirmation for multiple users
        if len(users) > 1:
            print(
                f"Found {len(users)} users. Do you want to proceed with "
                f"{args.command} operation on the users? (Y/N)"
            )
            confirmation = input("Type 'Y' to confirm: ").strip()
            if confirmation.upper() != "Y":
                print("Operation cancelled.")
                return

        if args.command == "disable":
            for user in users:
                disable(
                    args.url,
                    args.token,
                    user["guid"],
                    user["name"],
                    operation_id=args.operation_id if len(users) == 1 else None,
                )
                print("Success")
        elif args.command == "enable":
            for user in users:
                enable(
                    args.url,
                    args.token,
                    user["guid"],
                    user["name"],
                    operation_id=args.operation_id if len(users) == 1 else None,
                )
                print("Success")
        elif args.command == "delete":
            for user in users:
                delete_user(args.url, args.token, user["guid"], user["name"])
                print("Success")
        elif args.command == "force-logout":
            user_guids = [user["guid"] for user in users]
            force_logout(
                args.url, args.token, user_guids, operation_id=args.operation_id
            )
            print(f"Success: Force logout for {len(users)} user(s)")


if __name__ == "__main__":
    main()
