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
MACOS_ARM64_DEPLOYMENT_TARGET = "11.0"
APPLE_RUNNER = "macos-26"
XCODE_VERSION = "26.2"
XCODE_DEVELOPER_DIR = f"/Applications/Xcode_{XCODE_VERSION}.app/Contents/Developer"
TARGET_ONLY_VCPKG_DEPENDENCIES = {
    "aom",
    "cpu-features",
    "ffmpeg",
    "libjpeg-turbo",
    "libsodium",
    "libvpx",
    "libyuv",
    "mfx-dispatch",
    "oboe",
    "opus",
}


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


def require_job_runner(job: str, expected: str, source: str) -> None:
    values = unique_values(
        r"^ {4}runs-on:\s*([^\s#]+)",
        job,
        f"{source} runner",
    )
    require_values(values, expected, f"{source} runner")


def require_job_command(job: str, command: str, source: str) -> None:
    count = job.count(command)
    if count != 1:
        raise PolicyError(
            f"{source} must contain {command!r} exactly once, found {count}"
        )


def verify_apple_job_toolchain(job: str, source: str) -> None:
    require_job_runner(job, APPLE_RUNNER, source)
    require_job_environment(job, "XCODE_VERSION", XCODE_VERSION, source)
    require_job_environment(job, "DEVELOPER_DIR", XCODE_DEVELOPER_DIR, source)
    require_job_command(
        job,
        'bash .github/scripts/verify-xcode.sh "${{ env.XCODE_VERSION }}"',
        source,
    )


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


def verify_target_only_vcpkg_dependencies(manifest: dict[str, object]) -> None:
    dependencies = manifest.get("dependencies")
    if not isinstance(dependencies, list):
        raise PolicyError("vcpkg.json dependencies must be an array")
    host_runtime_dependencies: list[str] = []
    for dependency in dependencies:
        if isinstance(dependency, str):
            continue
        if not isinstance(dependency, dict) or not isinstance(
            dependency.get("name"), str
        ):
            raise PolicyError("vcpkg.json contains an invalid dependency declaration")
        name = dependency["name"]
        if name in TARGET_ONLY_VCPKG_DEPENDENCIES and dependency.get("host") is True:
            host_runtime_dependencies.append(name)
    if host_runtime_dependencies:
        raise PolicyError(
            "runtime libraries must not be duplicated for the build host: "
            + ", ".join(sorted(host_runtime_dependencies))
        )


def verify_libvpx_port() -> None:
    source = "res/vcpkg/libvpx/portfile.cmake"
    port = read(source)
    if re.search(r'set\(OPTIONS(?:_DEBUG|_RELEASE)?\s+"', port):
        raise PolicyError(
            f"{source} must pass configure options as a CMake list, not one shell argument"
        )
    if port.count('VCPKG_TARGET_ARCHITECTURE MATCHES "^(x86|x64)$"') != 1:
        raise PolicyError(f"{source} must limit NASM acquisition and use to x86/x64")
    if port.count("vcpkg_find_acquire_program(NASM)") != 1:
        raise PolicyError(f"{source} must acquire NASM exactly once")
    if port.count("set(AS_NASM --as=nasm)") != 1:
        raise PolicyError(f"{source} must configure NASM exactly once")
    expected_flags = {
        "--extra-cflags=-mmacosx-version-min=${VCPKG_OSX_DEPLOYMENT_TARGET}",
        "--extra-cxxflags=-mmacosx-version-min=${VCPKG_OSX_DEPLOYMENT_TARGET}",
        "--extra-cflags=-miphoneos-version-min=${VCPKG_OSX_DEPLOYMENT_TARGET}",
        "--extra-cxxflags=-miphoneos-version-min=${VCPKG_OSX_DEPLOYMENT_TARGET}",
    }
    missing = sorted(flag for flag in expected_flags if port.count(flag) != 1)
    if missing:
        raise PolicyError(
            f"{source} must inherit Apple triplet targets for every compiler: {missing}"
        )
    if port.count("${APPLE_DEPLOYMENT_FLAGS}") != 2:
        raise PolicyError(
            f"{source} must apply Apple deployment flags to release and debug builds"
        )
    if re.search(r"-m(?:macosx|iphoneos)-version-min=\d", port):
        raise PolicyError(f"{source} must not hard-code an Apple deployment target")
    metadata = json.loads(read("res/vcpkg/libvpx/vcpkg.json"))
    if metadata.get("port-version") != 1:
        raise PolicyError("the hardened libvpx overlay must use port-version 1")


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
    verify_target_only_vcpkg_dependencies(manifest)
    overlays = manifest.get("vcpkg-configuration", {}).get("overlay-triplets", [])
    if "./res/vcpkg-triplets" not in overlays:
        raise PolicyError("vcpkg.json must load ./res/vcpkg-triplets")

    verify_vcpkg_triplet(
        "res/vcpkg-triplets/arm64-ios.cmake", "iOS", "arm64", ios_target
    )
    verify_vcpkg_triplet(
        "res/vcpkg-triplets/arm64-osx.cmake",
        "Darwin",
        "arm64",
        MACOS_ARM64_DEPLOYMENT_TARGET,
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
    verify_libvpx_port()

    release = read(".github/workflows/release.yml")
    release_ios_job = workflow_job(
        release, "build_ios", ".github/workflows/release.yml"
    )
    release_macos_job = workflow_job(
        release, "build_macos_universal", ".github/workflows/release.yml"
    )
    require_job_environment(
        release_ios_job,
        "IPHONEOS_DEPLOYMENT_TARGET",
        ios_target,
        "release build_ios",
    )
    require_job_environment(
        release_macos_job,
        "MACOSX_DEPLOYMENT_TARGET",
        macos_target,
        "release build_macos_universal",
    )
    verify_apple_job_toolchain(release_ios_job, "release build_ios")
    verify_apple_job_toolchain(
        release_macos_job, "release build_macos_universal"
    )
    require_job_command(
        release_ios_job,
        "git diff --exit-code",
        "release build_ios source-migration gate",
    )
    require_job_command(
        release_macos_job,
        "git diff --exit-code",
        "release build_macos_universal source-migration gate",
    )
    require_job_command(
        release_macos_job,
        "flutter/build/macos/Build/Products/Release",
        "release build_macos_universal product discovery",
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
    verify_apple_job_toolchain(apple_job, "CI apple_native")
    require_job_command(
        apple_job,
        "flutter build ipa --release --no-codesign",
        "CI complete unsigned iOS application gate",
    )
    require_job_command(
        apple_job,
        "git diff --exit-code",
        "CI Apple source-migration gate",
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
        f"iOS {ios_target}, macOS {macos_target} "
        f"(Apple Silicon {MACOS_ARM64_DEPLOYMENT_TARGET})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
