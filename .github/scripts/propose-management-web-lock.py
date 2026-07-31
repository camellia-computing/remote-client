#!/usr/bin/env python3
"""Open an App-authored PR that advances Management's Web client lock."""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
from typing import Any
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen

COMMIT = re.compile(r"^[0-9a-f]{40}$")
NAME = re.compile(r"^[A-Za-z0-9._-]{1,100}$")
LOGIN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,99})\[bot\]$")
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
API_ENDPOINT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._~/%?=&:+-]*$")
API_ROOT = "https://api.github.com/"
LOGICAL_IDS = (
    "remote-client",
    "remote-management",
    "remote-protocol",
    "remote-server",
)


class GitHubApiError(RuntimeError):
    """A bounded GitHub REST failure with an inspectable HTTP status."""

    def __init__(self, status: int, detail: str) -> None:
        super().__init__(f"GitHub API returned HTTP {status}: {detail}")
        self.status = status


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def parse_json(value: str | bytes, label: str) -> Any:
    try:
        return json.loads(value, object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is not valid JSON") from error


def gh_json(
    endpoint: str,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
) -> Any:
    path = endpoint.partition("?")[0]
    if (
        method not in {"GET", "POST", "PUT"}
        or API_ENDPOINT.fullmatch(endpoint) is None
        or any(component in {"", ".", ".."} for component in path.split("/"))
    ):
        raise ValueError("GitHub API request is outside the reviewed REST surface")
    data = None
    if payload is not None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    request = Request(
        API_ROOT + endpoint,
        data=data,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            return parse_json(response.read(), "GitHub API response")
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")[:1000]
        raise GitHubApiError(error.code, detail) from error


def repository_map(value: str, current_repository: str) -> dict[str, str]:
    parsed = parse_json(value, "REMOTE_REPOSITORY_MAP")
    current_parts = current_repository.split("/")
    if (
        not isinstance(parsed, dict)
        or tuple(sorted(parsed)) != LOGICAL_IDS
        or any(
            not isinstance(parsed[item], str)
            or not NAME.fullmatch(parsed[item])
            or parsed[item] in {".", ".."}
            for item in LOGICAL_IDS
        )
    ):
        raise ValueError(
            "REMOTE_REPOSITORY_MAP must be the complete reviewed logical map"
        )
    if len(current_parts) != 2 or any(
        part in {".", ".."} or NAME.fullmatch(part) is None for part in current_parts
    ):
        raise ValueError("current repository must be a canonical owner/name")
    current_name = current_parts[1]
    if parsed["remote-client"].casefold() != current_name.casefold():
        raise ValueError("logical repository map does not match the current repository")
    if parsed["remote-management"].casefold() == current_name.casefold():
        raise ValueError("Remote Client and Management repository names must differ")
    return parsed


def validate_completed_release(
    repository: str,
    *,
    tag: str,
    commit: str,
    release_app_login: str,
) -> None:
    release = gh_json(f"repos/{repository}/releases/tags/{tag}")
    assets = release.get("assets") if isinstance(release, dict) else None
    body = release.get("body") if isinstance(release, dict) else None
    if (
        not isinstance(release, dict)
        or release.get("tag_name") != tag
        or release.get("target_commitish") != commit
        or release.get("draft") is not False
        or release.get("prerelease") is not False
        or release.get("immutable") is not True
        or release.get("author", {}).get("login") != release_app_login
        or not isinstance(body, str)
        or body.splitlines().count(f"<!-- release-complete:{commit} -->") != 1
        or not isinstance(assets, list)
        or [
            item.get("name")
            for item in assets
            if isinstance(item, dict) and item.get("name") == "release-evidence.json"
        ]
        != ["release-evidence.json"]
    ):
        raise ValueError("Remote Client release is not completed and immutable")


def decoded_content(value: Any, label: str) -> str:
    if (
        not isinstance(value, dict)
        or value.get("encoding") != "base64"
        or not isinstance(value.get("content"), str)
    ):
        raise ValueError(f"{label} response is invalid")
    try:
        encoded = "".join(value["content"].split())
        return base64.b64decode(encoded, validate=True).decode("utf-8")
    except (ValueError, UnicodeDecodeError) as error:
        raise ValueError(f"{label} is not valid UTF-8 base64") from error


def ensure_lock_pr(args: argparse.Namespace) -> str:
    mapping = repository_map(args.repository_map, args.current_repository)
    if not COMMIT.fullmatch(args.commit):
        raise ValueError("release commit must be a full lowercase SHA")
    commit = f"{int(args.commit, 16):040x}"
    version_match = SEMVER.fullmatch(args.version)
    if version_match is None:
        raise ValueError("release version and tag are inconsistent")
    version = ".".join(str(int(item)) for item in version_match.groups())
    tag = f"v{version}"
    if (
        commit != args.commit
        or version != args.version
        or args.tag != tag
        or LOGIN.fullmatch(args.release_app_login) is None
    ):
        raise ValueError("release version and tag are inconsistent")
    args.commit = commit
    args.version = version
    args.tag = tag
    owner = args.current_repository.split("/", 1)[0]
    client_repository = f"{owner}/{mapping['remote-client']}"
    management_repository = f"{owner}/{mapping['remote-management']}"
    validate_completed_release(
        client_repository,
        tag=args.tag,
        commit=args.commit,
        release_app_login=args.release_app_login,
    )

    repository = gh_json(f"repos/{management_repository}")
    default_branch = repository.get("default_branch")
    if default_branch != "main":
        raise ValueError("Management repository default branch must be main")
    encoded_default_branch = quote(default_branch, safe="")
    lock = gh_json(
        f"repos/{management_repository}/contents/web-client.lock"
        f"?ref={encoded_default_branch}"
    )
    lock_sha = lock.get("sha") if isinstance(lock, dict) else None
    current = decoded_content(lock, "web-client.lock").strip()
    if not isinstance(lock_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", lock_sha):
        raise ValueError("Management web-client.lock blob SHA is invalid")
    if not COMMIT.fullmatch(current):
        raise ValueError("Management web-client.lock content is invalid")
    if current == args.commit:
        return "already-current"

    branch = f"automation/remote-client-web-v{args.version}"
    encoded_branch = quote(branch, safe="")
    pulls = gh_json(
        f"repos/{management_repository}/pulls"
        f"?state=open&head={quote(f'{owner}:{branch}', safe='')}"
        f"&base={encoded_default_branch}"
    )
    if not isinstance(pulls, list):
        raise TypeError("Management pull request response is invalid")
    if len(pulls) > 1:
        raise ValueError("multiple open lock update pull requests use this branch")

    base_ref = gh_json(
        f"repos/{management_repository}/git/ref/heads/{encoded_default_branch}"
    )
    base_sha = base_ref.get("object", {}).get("sha")
    if not isinstance(base_sha, str) or not COMMIT.fullmatch(base_sha):
        raise ValueError("Management default branch ref is invalid")
    branch_ref: dict[str, Any] | None
    try:
        branch_ref = gh_json(
            f"repos/{management_repository}/git/ref/heads/{encoded_branch}"
        )
    except GitHubApiError as error:
        if error.status != 404:
            raise
        branch_ref = None
    if branch_ref is None:
        if pulls:
            raise ValueError("lock update PR exists without its source branch")
        gh_json(
            f"repos/{management_repository}/git/refs",
            method="POST",
            payload={"ref": f"refs/heads/{branch}", "sha": base_sha},
        )
        branch_ref = {
            "ref": f"refs/heads/{branch}",
            "object": {"type": "commit", "sha": base_sha},
        }

    branch_sha = branch_ref.get("object", {}).get("sha")
    if (
        branch_ref.get("ref") != f"refs/heads/{branch}"
        or branch_ref.get("object", {}).get("type") != "commit"
        or not isinstance(branch_sha, str)
        or not COMMIT.fullmatch(branch_sha)
    ):
        raise ValueError("Management lock update branch ref is invalid")

    branch_lock = gh_json(
        f"repos/{management_repository}/contents/web-client.lock?ref={encoded_branch}"
    )
    branch_lock_sha = branch_lock.get("sha") if isinstance(branch_lock, dict) else None
    branch_content = decoded_content(branch_lock, "branch web-client.lock").strip()
    if not isinstance(branch_lock_sha, str) or not COMMIT.fullmatch(branch_lock_sha):
        raise ValueError("branch web-client.lock blob SHA is invalid")
    if branch_content != args.commit:
        if branch_sha != base_sha or branch_content != current or pulls:
            raise ValueError(
                "existing lock update branch has conflicting content or history"
            )
        gh_json(
            f"repos/{management_repository}/contents/web-client.lock",
            method="PUT",
            payload={
                "message": f"chore(deps): bundle Remote Client v{args.version}",
                "content": base64.b64encode(f"{args.commit}\n".encode()).decode(),
                "sha": branch_lock_sha,
                "branch": branch,
            },
        )
        branch_lock = gh_json(
            f"repos/{management_repository}/contents/web-client.lock"
            f"?ref={encoded_branch}"
        )
    if decoded_content(branch_lock, "branch web-client.lock").strip() != args.commit:
        raise ValueError("existing lock update branch has conflicting content")

    if len(pulls) == 0:
        pull = gh_json(
            f"repos/{management_repository}/pulls",
            method="POST",
            payload={
                "title": (f"chore(deps): bundle Remote Client v{args.version}"),
                "head": branch,
                "base": default_branch,
                "body": (
                    "Advance the reviewed Web runtime lock to the completed "
                    f"Remote Client `{args.tag}` release.\n\n"
                    f"- Client commit: `{args.commit}`\n"
                    "- Publication: immutable, App-authored, and evidence-backed\n"
                    "- Merge remains subject to Management CI and human review.\n"
                ),
                "maintainer_can_modify": False,
            },
        )
    elif len(pulls) == 1:
        pull = pulls[0]
    else:
        raise ValueError("multiple open lock update pull requests use this branch")
    number = pull.get("number")
    if (
        not isinstance(number, int)
        or isinstance(number, bool)
        or number < 1
        or pull.get("state") != "open"
        or pull.get("draft") is not False
        or pull.get("user", {}).get("login") != args.release_app_login
        or pull.get("head", {}).get("ref") != branch
        or str(pull.get("head", {}).get("repo", {}).get("full_name", "")).casefold()
        != management_repository.casefold()
        or pull.get("base", {}).get("ref") != default_branch
    ):
        raise ValueError("Management lock update PR has no valid number")
    files = gh_json(f"repos/{management_repository}/pulls/{number}/files?per_page=100")
    if (
        not isinstance(files, list)
        or len(files) != 1
        or files[0].get("filename") != "web-client.lock"
        or files[0].get("status") not in {"modified", "changed"}
    ):
        raise ValueError("Management lock update PR changes unexpected files")
    return str(number)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--repository-map", required=True)
    result.add_argument("--current-repository", required=True)
    result.add_argument("--release-app-login", required=True)
    result.add_argument("--version", required=True)
    result.add_argument("--tag", required=True)
    result.add_argument("--commit", required=True)
    return result


def main() -> None:
    if not os.environ.get("GH_TOKEN"):
        raise ValueError("GH_TOKEN is required")
    result = ensure_lock_pr(parser().parse_args())
    print(f"Management Web lock update: {result}")


if __name__ == "__main__":
    main()
