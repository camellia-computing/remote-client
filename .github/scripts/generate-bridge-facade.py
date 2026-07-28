#!/usr/bin/env python3
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FFI = ROOT / "flutter/lib/generated_bridge/flutter_ffi.dart"
OUT = ROOT / "flutter/lib/generated_bridge.dart"


FUNCTION_RE = re.compile(
    r"""
    ^\s*
    (?P<return_type>[A-Za-z_][A-Za-z0-9_<>,?. \t]*?)
    \s+
    (?P<name>[A-Za-z_][A-Za-z0-9_]*)
    \s*
    \(
      (?P<params>.*?)
    \)
    \s*=>\s*
    RustLib\s*\.\s*instance\s*\.\s*api\s*\.\s*[A-Za-z_][A-Za-z0-9_]*
    \(
      .*?
    \)
    \s*;
    """,
    re.DOTALL | re.MULTILINE | re.VERBOSE,
)


def normalize_space(value: str) -> str:
    return " ".join(value.split())


def split_top_level(value: str) -> list[str]:
    parts = []
    start = 0
    angle_depth = 0
    for index, char in enumerate(value):
        if char == "<":
            angle_depth += 1
        elif char == ">":
            angle_depth = max(angle_depth - 1, 0)
        elif char == "," and angle_depth == 0:
            part = value[start:index].strip()
            if part:
                parts.append(part)
            start = index + 1

    tail = value[start:].strip()
    if tail:
        parts.append(tail)
    return parts


def parameter_name(parameter: str) -> str:
    match = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*(?:=.*)?$", parameter)
    if not match:
        raise ValueError(f"Unsupported named parameter: {parameter}")
    return match.group(1)


def public_parameter_name(name: str) -> str:
    return name[:-1] if name.endswith("_") else name


def public_parameter(parameter: str, private_name: str, public_name: str) -> str:
    if private_name == public_name:
        return parameter
    return re.sub(
        rf"\b{re.escape(private_name)}\b(\s*(?:=.*)?$)",
        rf"{public_name}\1",
        parameter,
    )


def parse_methods(source: str) -> list[str]:
    methods = []
    for match in FUNCTION_RE.finditer(source):
        return_type, name, params = match.group("return_type", "name", "params")
        return_type = normalize_space(return_type)
        params = normalize_space(params)

        if params.startswith("{") and params.endswith("}"):
            inner = params[1:-1].strip()
            private_parts = split_top_level(inner)
            mapped_params = []
            call_args = []
            for part in private_parts:
                private_name = parameter_name(part)
                public_name = public_parameter_name(private_name)
                mapped_params.append(public_parameter(part, private_name, public_name))
                call_args.append(f"{private_name}: {public_name}")
            params = "{" + ", ".join(mapped_params) + "}"
            call_args = ", ".join(call_args)
        elif params:
            raise ValueError(f"Unsupported positional parameters for {name}: {params}")
        else:
            call_args = ""

        methods.append(
            f"  {return_type} {name}({params}) => ffi.{name}({call_args});"
        )

    return methods


def main() -> None:
    methods = parse_methods(FFI.read_text())

    if not methods:
        raise RuntimeError(f"No bridge functions parsed from {FFI}")

    OUT.write_text(
        """import 'dart:async';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'generated_bridge/flutter_ffi.dart' as ffi;
import 'generated_bridge/flutter_ffi.dart' show EventToUI;

export 'generated_bridge/frb_generated.dart';
export 'generated_bridge/flutter_ffi.dart' hide translate;
export 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

class RustdeskImpl {
  const RustdeskImpl();

"""
        + "\n".join(methods)
        + "\n}\n"
    )

    print(f"Generated {len(methods)} RustdeskImpl bridge facade methods")


if __name__ == "__main__":
    main()
