#!/usr/bin/env python3
"""Fail closed when Apple deployment targets drift between build systems."""

from __future__ import annotations

import json
from pathlib import Path
import plistlib
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
SUPPORTED_FLOORS = {"ios": (13, 0), "macos": (10, 15)}


class PolicyError(ValueError):
    """An Apple build surface does not match the product deployment policy."""


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def version_tuple(value: str, source: str) -> tuple[int, int]:
    if not re.fullmatch(r"\d+\.\d+", value):
        raise PolicyError(
            f"{source} must use a major.minor deployment target, got {value!r}"
        )
    major, minor = value.split(".", maxsplit=1)
    return int(major), int(minor)


def unique_values(pattern: str, text: str, source: str) -> set[str]:
    values = {
        match.strip().strip('"\'')
        for match in re.findall(pattern, text, re.MULTILINE)
    }
    if not values:
        raise PolicyError(f"{source} does not declare a deployment target")
    return values


def require_values(values: set[str], expected: str, source: str) -> None:
    if values != {expected}:
        raise PolicyError(f"{source} must declare only {expected}, got {sorted(values)}")


def workflow_job(workflow: str, job_name: str, source: str) -> str:
    match = re.search(
        rf"^  {re.escape(job_name)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        workflow,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise PolicyError(f"{source} is missing the {job_name} job")
    return match.group("body")


def require_job_environment(
    job: str, variable: str, expected: str, source: str
) -> None:
    values = unique_values(
        rf"^ {{6}}{re.escape(variable)}:\s*([^\s#]+)",
        job,
        f"{source} {variable}",
    )
    require_values(values, expected, f"{source} {variable}")


def plist_ios_target() -> str:
    path = ROOT / "flutter/ios/Flutter/AppFrameworkInfo.plist"
    with path.open("rb") as stream:
        value = plistlib.load(stream).get("MinimumOSVersion")
    if not isinstance(value, str):
        raise PolicyError(
            f"{path.relative_to(ROOT)} is missing a string MinimumOSVersion"
        )
    return value


def xcode_macos_target() -> str:
    source = "flutter/macos/Runner.xcodeproj/project.pbxproj"
    values = unique_values(
        r"\bMACOSX_DEPLOYMENT_TARGET\s*=\s*([^;]+);",
        read(source),
        source,
    )
    if len(values) != 1:
        raise PolicyError(
            f"{source} has conflicting deployment targets: {sorted(values)}"
        )
    return values.pop()


def verify_supported_floor(platform: str, value: str) -> None:
    actual = version_tuple(value, f"{platform} policy")
    if actual < SUPPORTED_FLOORS[platform]:
        floor = ".".join(str(part) for part in SUPPORTED_FLOORS[platform])
        raise PolicyError(
            f"{platform} target {value} is below the supported floor {floor}"
        )


def verify_vcpkg_triplet(
    path: str, system: str, architecture: str, expected: str
) -> None:
    text = read(path)
    require_values(
        unique_values(
            r"set\(VCPKG_CMAKE_SYSTEM_NAME\s+([^)]+)\)",
            text,
            f"{path} system",
        ),
        system,
        f"{path} system",
    )
    require_values(
        unique_values(
            r"set\(VCPKG_OSX_ARCHITECTURES\s+([^)]+)\)",
            text,
            f"{path} architecture",
        ),
        architecture,
        f"{path} architecture",
    )
    require_values(
        unique_values(
            r"set\(VCPKG_OSX_DEPLOYMENT_TARGET\s+([^)]+)\)",
            text,
            f"{path} deployment target",
        ),
        expected,
        f"{path} deployment target",
    )


def verify() -> tuple[str, str]:
    ios_target = plist_ios_target()
    macos_target = xcode_macos_target()
    verify_supported_floor("ios", ios_target)
    verify_supported_floor("macos", macos_target)

    ios_podfile = read("flutter/ios/Podfile")
    require_values(
        unique_values(
            r"^\s*platform\s+:ios,\s*['\"]([^'\"]+)['\"]",
            ios_podfile,
            "flutter/ios/Podfile platform",
        ),
        ios_target,
        "flutter/ios/Podfile platform",
    )
    if "IPHONEOS_DEPLOYMENT_TARGET" in ios_podfile:
        raise PolicyError(
            "flutter/ios/Podfile must not override individual pod deployment targets"
        )
    require_values(
        unique_values(
            r"\bIPHONEOS_DEPLOYMENT_TARGET\s*=\s*([^;]+);",
            read("flutter/ios/Runner.xcodeproj/project.pbxproj"),
            "flutter/ios/Runner.xcodeproj/project.pbxproj",
        ),
        ios_target,
        "flutter/ios/Runner.xcodeproj/project.pbxproj",
    )
    require_values(
        unique_values(
            r"^\s*platform\s+:osx,\s*['\"]([^'\"]+)['\"]",
            read("flutter/macos/Podfile"),
            "flutter/macos/Podfile platform",
        ),
        macos_target,
        "flutter/macos/Podfile platform",
    )

    manifest = json.loads(read("vcpkg.json"))
    overlays = manifest.get("vcpkg-configuration", {}).get("overlay-triplets", [])
    if "./res/vcpkg-triplets" not in overlays:
        raise PolicyError("vcpkg.json must load ./res/vcpkg-triplets")

    verify_vcpkg_triplet(
        "res/vcpkg-triplets/arm64-ios.cmake", "iOS", "arm64", ios_target
    )
    verify_vcpkg_triplet(
        "res/vcpkg-triplets/arm64-osx.cmake", "Darwin", "arm64", macos_target
    )
    verify_vcpkg_triplet(
        "res/vcpkg-triplets/x64-osx.cmake", "Darwin", "x86_64", macos_target
    )

    ffmpeg = read("res/vcpkg/ffmpeg/portfile.cmake")
    expected_flag = "-mios-version-min=${VCPKG_OSX_DEPLOYMENT_TARGET}"
    if ffmpeg.count(expected_flag) != 2:
        raise PolicyError(
            "the iOS FFmpeg compiler and linker must inherit the triplet target"
        )
    if re.search(r"-mios-version-min=\d", ffmpeg):
        raise PolicyError("the iOS FFmpeg port must not hard-code a deployment target")

    release = read(".github/workflows/release.yml")
    require_job_environment(
        workflow_job(release, "build_ios", ".github/workflows/release.yml"),
        "IPHONEOS_DEPLOYMENT_TARGET",
        ios_target,
        "release build_ios",
    )
    require_job_environment(
        workflow_job(release, "build_macos_universal", ".github/workflows/release.yml"),
        "MACOSX_DEPLOYMENT_TARGET",
        macos_target,
        "release build_macos_universal",
    )

    ci = read(".github/workflows/ci.yml")
    apple_job = workflow_job(ci, "apple_native", ".github/workflows/ci.yml")
    require_job_environment(
        apple_job,
        "IPHONEOS_DEPLOYMENT_TARGET",
        ios_target,
        "CI apple_native",
    )
    require_job_environment(
        apple_job,
        "MACOSX_DEPLOYMENT_TARGET",
        macos_target,
        "CI apple_native",
    )

    return ios_target, macos_target


def main() -> int:
    try:
        ios_target, macos_target = verify()
    except (
        OSError,
        json.JSONDecodeError,
        plistlib.InvalidFileException,
        PolicyError,
    ) as error:
        print(f"Apple deployment policy violation: {error}", file=sys.stderr)
        return 1
    print(
        "Apple deployment policy is consistent: "
        f"iOS {ios_target}, macOS {macos_target}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
