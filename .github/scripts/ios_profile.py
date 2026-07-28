#!/usr/bin/env python3
"""Validate iOS provisioning profiles and signed app metadata."""

from __future__ import annotations

import argparse
import hashlib
import plistlib
import re
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


EXPORT_METHODS = {
    "app-store-connect",
    "release-testing",
    "debugging",
    "enterprise",
}


def load_plist(path: Path) -> dict[str, Any]:
    value = plistlib.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise ValueError(f"{path} does not contain a plist dictionary")
    return value


def required_string(mapping: dict[str, Any], name: str) -> str:
    value = mapping.get(name)
    if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
        raise ValueError(f"{name} must be a non-empty single-line string")
    return value


def normalized_certificate_digest(value: str) -> str:
    digest = value.replace(":", "").upper()
    if not re.fullmatch(r"[0-9A-F]{64}", digest):
        raise ValueError("certificate SHA-256 must contain exactly 64 hexadecimal digits")
    return digest


def validate_profile(
    profile: dict[str, Any],
    *,
    bundle_id: str,
    team_id: str,
    export_method: str,
    certificate_sha256: str,
    now: datetime | None = None,
) -> dict[str, str]:
    if export_method not in EXPORT_METHODS:
        raise ValueError(f"unsupported iOS export method: {export_method}")
    if not re.fullmatch(r"[A-Z0-9]{10}", team_id):
        raise ValueError("team ID must contain 10 uppercase letters or digits")

    raw_uuid = required_string(profile, "UUID")
    try:
        profile_uuid = str(uuid.UUID(raw_uuid)).upper()
    except ValueError as error:
        raise ValueError("profile UUID is not canonical") from error
    profile_name = required_string(profile, "Name")

    team_identifiers = profile.get("TeamIdentifier")
    if not isinstance(team_identifiers, list) or team_id not in team_identifiers:
        raise ValueError("provisioning profile TeamIdentifier does not match IOS_TEAM_ID")

    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        raise ValueError("provisioning profile does not contain entitlements")
    expected_application_id = f"{team_id}.{bundle_id}"
    if entitlements.get("application-identifier") != expected_application_id:
        raise ValueError(
            "provisioning profile application-identifier does not exactly match the app"
        )
    if entitlements.get("com.apple.developer.team-identifier") != team_id:
        raise ValueError("provisioning profile team entitlement does not match IOS_TEAM_ID")

    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime):
        raise ValueError("provisioning profile ExpirationDate is unavailable")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=UTC)
    current = now or datetime.now(UTC)
    if current.tzinfo is None:
        current = current.replace(tzinfo=UTC)
    if expiration <= current:
        raise ValueError("provisioning profile is expired")

    provisioned_devices = profile.get("ProvisionedDevices")
    has_devices = isinstance(provisioned_devices, list) and bool(provisioned_devices)
    provisions_all_devices = profile.get("ProvisionsAllDevices") is True
    allows_debugging = entitlements.get("get-task-allow") is True
    if export_method == "app-store-connect":
        valid_kind = not has_devices and not provisions_all_devices and not allows_debugging
    elif export_method == "release-testing":
        valid_kind = has_devices and not provisions_all_devices and not allows_debugging
    elif export_method == "debugging":
        valid_kind = has_devices and not provisions_all_devices and allows_debugging
    else:
        valid_kind = provisions_all_devices and not has_devices and not allows_debugging
    if not valid_kind:
        raise ValueError(
            f"provisioning profile type does not match IOS_EXPORT_METHOD={export_method}"
        )

    expected_digest = normalized_certificate_digest(certificate_sha256)
    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not certificates:
        raise ValueError("provisioning profile does not contain developer certificates")
    certificate_digests = {
        hashlib.sha256(bytes(certificate)).hexdigest().upper()
        for certificate in certificates
        if isinstance(certificate, (bytes, bytearray))
    }
    if expected_digest not in certificate_digests:
        raise ValueError("configured signing certificate is not authorized by the profile")

    return {
        "profile_uuid": profile_uuid,
        "profile_name": profile_name,
        "certificate_sha256": expected_digest,
        "expiration": expiration.astimezone(UTC).isoformat(),
    }


def validate_signed_app(
    info: dict[str, Any],
    entitlements: dict[str, Any],
    *,
    bundle_id: str,
    team_id: str,
    export_method: str,
) -> None:
    if info.get("CFBundleIdentifier") != bundle_id:
        raise ValueError("signed app bundle identifier does not match IOS_BUNDLE_ID")
    if entitlements.get("application-identifier") != f"{team_id}.{bundle_id}":
        raise ValueError("signed app application-identifier is unexpected")
    if entitlements.get("com.apple.developer.team-identifier") != team_id:
        raise ValueError("signed app Team ID entitlement is unexpected")
    allows_debugging = entitlements.get("get-task-allow") is True
    if allows_debugging != (export_method == "debugging"):
        raise ValueError("signed app get-task-allow does not match IOS_EXPORT_METHOD")


def write_export_configuration(
    *,
    output: Path,
    environment_output: Path,
    profile: dict[str, str],
    bundle_id: str,
    team_id: str,
    export_method: str,
    signing_identity: str,
) -> None:
    options = {
        "destination": "export",
        "manageAppVersionAndBuildNumber": False,
        "method": export_method,
        "provisioningProfiles": {bundle_id: profile["profile_uuid"]},
        "signingCertificate": signing_identity,
        "signingStyle": "manual",
        "stripSwiftSymbols": True,
        "teamID": team_id,
    }
    output.write_bytes(plistlib.dumps(options, fmt=plistlib.FMT_XML, sort_keys=True))
    environment_output.write_text(
        "\n".join(
            (
                f"IOS_PROFILE_UUID={profile['profile_uuid']}",
                f"IOS_SIGNING_IDENTITY_SHA256={profile['certificate_sha256']}",
                f"IOS_EXPORT_OPTIONS_PLIST={output}",
            )
        )
        + "\n",
        encoding="utf-8",
    )


def validate_command(args: argparse.Namespace) -> None:
    profile = validate_profile(
        load_plist(Path(args.profile_plist)),
        bundle_id=args.bundle_id,
        team_id=args.team_id,
        export_method=args.export_method,
        certificate_sha256=args.certificate_sha256,
    )
    generation_values = (args.export_options, args.environment_output, args.signing_identity)
    if any(generation_values) and not all(generation_values):
        raise ValueError(
            "--export-options, --environment-output and --signing-identity "
            "must be provided together"
        )
    if all(generation_values):
        write_export_configuration(
            output=Path(args.export_options),
            environment_output=Path(args.environment_output),
            profile=profile,
            bundle_id=args.bundle_id,
            team_id=args.team_id,
            export_method=args.export_method,
            signing_identity=args.signing_identity,
        )
    print(
        "Validated iOS provisioning profile "
        f"{profile['profile_uuid']} (expires {profile['expiration']})"
    )


def verify_app_command(args: argparse.Namespace) -> None:
    validate_signed_app(
        load_plist(Path(args.info_plist)),
        load_plist(Path(args.entitlements_plist)),
        bundle_id=args.bundle_id,
        team_id=args.team_id,
        export_method=args.export_method,
    )
    print("Validated signed iOS bundle metadata and entitlements")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    subcommands = root.add_subparsers(dest="command", required=True)

    validate = subcommands.add_parser("validate")
    validate.add_argument("--profile-plist", required=True)
    validate.add_argument("--bundle-id", required=True)
    validate.add_argument("--team-id", required=True)
    validate.add_argument("--export-method", required=True, choices=sorted(EXPORT_METHODS))
    validate.add_argument("--certificate-sha256", required=True)
    validate.add_argument("--export-options")
    validate.add_argument("--environment-output")
    validate.add_argument("--signing-identity")
    validate.set_defaults(handler=validate_command)

    verify = subcommands.add_parser("verify-app")
    verify.add_argument("--info-plist", required=True)
    verify.add_argument("--entitlements-plist", required=True)
    verify.add_argument("--bundle-id", required=True)
    verify.add_argument("--team-id", required=True)
    verify.add_argument("--export-method", required=True, choices=sorted(EXPORT_METHODS))
    verify.set_defaults(handler=verify_app_command)
    return root


def main() -> None:
    args = parser().parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
