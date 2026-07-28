#!/usr/bin/env python3
"""Build the deterministic archive embedded in the Windows portable launcher."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from hashlib import sha256
import os
from pathlib import Path
import subprocess
import sys
from typing import Callable, Sequence


ARCHIVE_MAGIC = b"CAMELP01"
MAX_FILE_COUNT = 100_000
MAX_PATH_BYTES = 32 * 1024
MAX_FILE_BYTES = 1024 * 1024 * 1024
UINT32_BYTES = 4
UINT64_BYTES = 8

Compressor = Callable[..., bytes]


@dataclass(frozen=True)
class PackageEntry:
    path: str
    compressed_data: bytes
    uncompressed_size: int
    sha256_digest: bytes


def _as_uint(value: int, length: int, label: str) -> bytes:
    try:
        return value.to_bytes(length=length, byteorder="big")
    except OverflowError as error:
        raise ValueError(f"{label} is too large for the portable archive") from error


def validate_source_folder(folder: str | os.PathLike[str]) -> Path:
    supplied = Path(folder)
    if supplied.is_symlink():
        raise ValueError("source folder must not be a symbolic link")
    source = supplied.resolve(strict=True)
    if not source.is_dir():
        raise ValueError(f"source folder is not a directory: {source}")
    return source


def validate_output_folder(
    output_folder: str | os.PathLike[str], source: Path
) -> Path:
    supplied = Path(output_folder)
    if supplied.is_symlink():
        raise ValueError("output folder must not be a symbolic link")
    output = supplied.resolve()
    try:
        output.relative_to(source)
    except ValueError:
        pass
    else:
        raise ValueError("output folder must not be inside the source folder")
    output.mkdir(parents=True, exist_ok=True)
    if output.is_symlink() or not output.is_dir():
        raise ValueError(f"output folder is not a regular directory: {output}")
    return output


def encode_archive_path(path: str, label: str) -> bytes:
    encoded = path.encode("utf-8")
    if (
        not encoded
        or len(encoded) > MAX_PATH_BYTES
        or "\\" in path
        or ":" in path
        or "\0" in path
        or any(component in {"", ".", ".."} for component in path.split("/"))
    ):
        raise ValueError(f"{label} is not a normalized portable path: {path!r}")
    return encoded


def resolve_executable(source: Path, executable: str | os.PathLike[str]) -> str:
    supplied = Path(executable)
    candidate = supplied if supplied.is_absolute() else source / supplied
    if candidate.is_symlink():
        raise ValueError("portable executable must not be a symbolic link")
    resolved = candidate.resolve(strict=True)
    try:
        relative = resolved.relative_to(source)
    except ValueError as error:
        raise ValueError(
            "portable executable must be located inside the source folder"
        ) from error
    if not resolved.is_file():
        raise ValueError(f"portable executable is not a regular file: {resolved}")
    executable_path = relative.as_posix()
    encode_archive_path(executable_path, "portable executable path")
    return executable_path


def collect_files(
    source: Path, quality: int, compressor: Compressor
) -> list[PackageEntry]:
    entries: list[PackageEntry] = []
    for root_name, directory_names, file_names in os.walk(
        source, topdown=True, followlinks=False
    ):
        directory_names.sort()
        file_names.sort()
        root = Path(root_name)

        for directory_name in directory_names:
            directory = root / directory_name
            if directory.is_symlink():
                raise ValueError(
                    f"source folder contains a symbolic-link directory: {directory}"
                )

        for file_name in file_names:
            path = root / file_name
            if path.is_symlink():
                raise ValueError(
                    f"source folder contains a symbolic-link file: {path}"
                )
            if not path.is_file():
                raise ValueError(f"source entry is not a regular file: {path}")

            relative = path.relative_to(source).as_posix()
            encode_archive_path(relative, "portable archive path")

            content = path.read_bytes()
            if len(content) > MAX_FILE_BYTES:
                raise ValueError(
                    f"source file exceeds the {MAX_FILE_BYTES}-byte limit: {relative}"
                )
            print(f"Compressing {relative}...")
            compressed = compressor(content, quality=quality)
            if len(compressed) > MAX_FILE_BYTES:
                raise ValueError(
                    f"compressed file exceeds the {MAX_FILE_BYTES}-byte limit: {relative}"
                )
            entries.append(
                PackageEntry(
                    path=relative,
                    compressed_data=compressed,
                    uncompressed_size=len(content),
                    sha256_digest=sha256(content).digest(),
                )
            )

            if len(entries) > MAX_FILE_COUNT:
                raise ValueError(
                    f"source folder exceeds the {MAX_FILE_COUNT}-file limit"
                )

    if not entries:
        raise ValueError("source folder does not contain any files")
    return entries


def write_package(
    entries: Sequence[PackageEntry], output: Path, executable: str
) -> tuple[Path, str]:
    output_path = output / "data.bin"
    temporary_path = output / "data.bin.tmp"
    executable_bytes = encode_archive_path(
        executable, "portable executable path"
    )
    if not entries or len(entries) > MAX_FILE_COUNT:
        raise ValueError("portable archive has an invalid file count")
    paths: set[str] = set()
    for entry in entries:
        encode_archive_path(entry.path, "portable archive path")
        if entry.path in paths:
            raise ValueError(f"portable archive path is duplicated: {entry.path}")
        paths.add(entry.path)
        if (
            entry.uncompressed_size < 0
            or entry.uncompressed_size > MAX_FILE_BYTES
            or len(entry.compressed_data) > MAX_FILE_BYTES
            or len(entry.sha256_digest) != sha256().digest_size
        ):
            raise ValueError(f"portable archive entry is invalid: {entry.path}")
    if executable not in paths:
        raise ValueError("portable executable is not included in the archive")

    try:
        with temporary_path.open("xb") as archive:
            archive.write(ARCHIVE_MAGIC)
            archive.write(_as_uint(len(entries), UINT32_BYTES, "file count"))
            for entry in entries:
                path_bytes = entry.path.encode("utf-8")
                archive.write(
                    _as_uint(len(path_bytes), UINT32_BYTES, "file path length")
                )
                archive.write(
                    _as_uint(
                        len(entry.compressed_data),
                        UINT64_BYTES,
                        "compressed file length",
                    )
                )
                archive.write(
                    _as_uint(
                        entry.uncompressed_size,
                        UINT64_BYTES,
                        "uncompressed file length",
                    )
                )
                archive.write(entry.sha256_digest)
                archive.write(path_bytes)
                archive.write(entry.compressed_data)
            archive.write(
                _as_uint(
                    len(executable_bytes), UINT32_BYTES, "executable path length"
                )
            )
            archive.write(executable_bytes)
        temporary_path.replace(output_path)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise

    digest = sha256()
    with output_path.open("rb") as archive:
        while chunk := archive.read(1024 * 1024):
            digest.update(chunk)
    package_sha256 = digest.hexdigest()
    print(f"Portable archive written to {output_path}")
    return output_path, package_sha256


def write_app_metadata(output: Path, package_sha256: str) -> Path:
    output_path = output / "app_metadata.toml"
    temporary_path = output / "app_metadata.toml.tmp"
    try:
        with temporary_path.open("x", encoding="utf-8", newline="\n") as metadata:
            metadata.write(f'package_sha256 = "{package_sha256}"\n')
        temporary_path.replace(output_path)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise
    print(f"Portable metadata written to {output_path}")
    return output_path


def build_portable(output: Path, target: str | None) -> None:
    command = ["cargo", "build", "--locked", "--release"]
    if target:
        command.extend(["--target", target])
    subprocess.run(command, cwd=output, check=True)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "-f", "--folder", default="./rustdesk", help="folder to compress"
    )
    parser.add_argument(
        "-o",
        "--output",
        default=".",
        help="portable packer project directory",
    )
    parser.add_argument(
        "-e",
        "--executable",
        default="camellia-remote.exe",
        help="startup file relative to --folder",
    )
    parser.add_argument("-t", "--target", help="optional Rust compilation target")
    parser.add_argument(
        "-l",
        "--level",
        type=int,
        choices=range(0, 12),
        default=11,
        metavar="0..11",
        help="Brotli compression quality (default: 11)",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    options = parse_args(argv)
    try:
        import brotli

        source = validate_source_folder(options.folder)
        output = validate_output_folder(options.output, source)
        executable = resolve_executable(source, options.executable)
        print(f"Executable path: {executable}")
        print(f"Compression level: {options.level}")
        entries = collect_files(source, options.level, brotli.compress)
        entry_paths = {entry.path for entry in entries}
        if executable not in entry_paths:
            raise ValueError("portable executable is not included in the archive")
        _, package_sha256 = write_package(entries, output, executable)
        write_app_metadata(output, package_sha256)
        build_portable(output, options.target)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Portable package generation failed: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
