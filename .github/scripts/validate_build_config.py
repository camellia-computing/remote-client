#!/usr/bin/env python3
"""Reject release configuration that would produce unusable client packages."""

from __future__ import annotations

import base64
import binascii
import ipaddress
import os
import re
import sys
from urllib.parse import urlsplit


class ConfigurationError(ValueError):
    """A release build setting is missing or malformed."""


def _require_clean_value(name: str, value: str) -> str:
    if not value:
        raise ConfigurationError(f"{name} is required for release builds")
    if value != value.strip() or any(character.isspace() for character in value):
        raise ConfigurationError(f"{name} must not contain whitespace")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ConfigurationError(f"{name} must not contain control characters")
    return value


def validate_rs_pub_key(value: str) -> None:
    value = _require_clean_value("RS_PUB_KEY", value)
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ConfigurationError(
            "RS_PUB_KEY must be canonical standard Base64"
        ) from error
    if len(decoded) != 32:
        raise ConfigurationError(
            "RS_PUB_KEY must decode to a 32-byte Ed25519 public key"
        )
    if base64.b64encode(decoded).decode("ascii") != value:
        raise ConfigurationError("RS_PUB_KEY must be canonical standard Base64")
    if not any(decoded):
        raise ConfigurationError("RS_PUB_KEY must not be the all-zero key")


def _validate_host(host: str, label: str) -> None:
    if not host or len(host) > 253 or "%" in host:
        raise ConfigurationError(f"{label} contains an invalid hostname")
    try:
        ipaddress.ip_address(host)
        return
    except ValueError:
        pass
    if re.fullmatch(r"[0-9.]+", host):
        raise ConfigurationError(f"{label} contains an invalid IP address")
    labels = host.split(".")
    if any(
        not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", part)
        for part in labels
    ):
        raise ConfigurationError(f"{label} contains an invalid hostname")


def _validate_server_endpoint(server: str) -> None:
    if any(character in server for character in "/?#@"):
        raise ConfigurationError(
            "RENDEZVOUS_SERVERS entries must be hostnames or IP addresses, not URLs"
        )
    host = server
    port_text = ""
    if server.startswith("["):
        closing = server.find("]")
        if closing < 0:
            raise ConfigurationError(
                "RENDEZVOUS_SERVERS contains an invalid bracketed IPv6 address"
            )
        host = server[1:closing]
        suffix = server[closing + 1 :]
        if suffix:
            if not suffix.startswith(":") or not suffix[1:]:
                raise ConfigurationError(
                    "RENDEZVOUS_SERVERS contains an invalid port"
                )
            port_text = suffix[1:]
        try:
            parsed_ip = ipaddress.ip_address(host)
        except ValueError as error:
            raise ConfigurationError(
                "RENDEZVOUS_SERVERS contains an invalid IPv6 address"
            ) from error
        if parsed_ip.version != 6:
            raise ConfigurationError(
                "RENDEZVOUS_SERVERS brackets are only valid for IPv6 addresses"
            )
    elif server.count(":") > 1:
        raise ConfigurationError(
            "RENDEZVOUS_SERVERS IPv6 addresses must use brackets"
        )
    elif ":" in server:
        host, port_text = server.rsplit(":", 1)
        if not port_text:
            raise ConfigurationError(
                "RENDEZVOUS_SERVERS contains an invalid port"
            )

    _validate_host(host, "RENDEZVOUS_SERVERS")
    if port_text:
        if not port_text.isascii() or not port_text.isdecimal():
            raise ConfigurationError(
                "RENDEZVOUS_SERVERS contains a non-numeric port"
            )
        port = int(port_text)
        if not 1 <= port <= 65535:
            raise ConfigurationError(
                "RENDEZVOUS_SERVERS contains a port outside 1-65535"
            )


def validate_rendezvous_servers(value: str) -> None:
    value = _require_clean_value("RENDEZVOUS_SERVERS", value)
    servers = value.split(",")
    if any(not server for server in servers):
        raise ConfigurationError(
            "RENDEZVOUS_SERVERS must be a comma-separated list without empty entries"
        )
    if len(set(servers)) != len(servers):
        raise ConfigurationError("RENDEZVOUS_SERVERS must not contain duplicates")
    for server in servers:
        if len(server) > 255:
            raise ConfigurationError("A rendezvous server entry is too long")
        _validate_server_endpoint(server)


def validate_api_server(value: str) -> None:
    value = _require_clean_value("API_SERVER", value)
    try:
        parsed = urlsplit(value)
    except ValueError as error:
        raise ConfigurationError("API_SERVER is not a valid URL") from error
    if parsed.scheme != "https" or not parsed.hostname:
        raise ConfigurationError(
            "API_SERVER must be an absolute HTTPS URL with a hostname"
        )
    _validate_host(parsed.hostname, "API_SERVER")
    if parsed.username is not None or parsed.password is not None:
        raise ConfigurationError("API_SERVER must not contain credentials")
    if parsed.query or parsed.fragment:
        raise ConfigurationError("API_SERVER must not contain a query or fragment")
    try:
        port = parsed.port
    except ValueError as error:
        raise ConfigurationError("API_SERVER contains an invalid port") from error
    if port is not None and not 1 <= port <= 65535:
        raise ConfigurationError("API_SERVER contains a port outside 1-65535")


def validate_environment(environment: dict[str, str]) -> None:
    validate_rs_pub_key(environment.get("RS_PUB_KEY", ""))
    validate_rendezvous_servers(environment.get("RENDEZVOUS_SERVERS", ""))
    validate_api_server(environment.get("API_SERVER", ""))


def main() -> int:
    try:
        validate_environment(os.environ)
    except ConfigurationError as error:
        print(f"Release build configuration error: {error}", file=sys.stderr)
        return 2
    print("Release build configuration is valid.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
