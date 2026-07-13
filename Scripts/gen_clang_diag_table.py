#!/usr/bin/env python3
"""
Generate stable Kairo backend diagnostic codes from Clang warning groups.

Typical usage:

    ./build/x86_64-linux-gnu/debug/bin/clang-diag-identity \
        | python3 Scripts/gen_clang_diag_table.py \
            --manifest Compiler/Diagnostic/TableGen/ClangDiagCodes.toml \
            --output Compiler/Diagnostic/TableGen/Clang.diag.toml

The manifest is the persistent allocation ledger. Check it into source
control. Never delete old entries or renumber existing entries.

The generated .diag.toml may then be consumed by gen_diag.py normally.
"""

from __future__ import annotations

import argparse
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

PREFIX = "C"
MIN_NUMBER = 1
MAX_NUMBER = 9999

SEVERITIES: tuple[tuple[str, str, str], ...] = (
    (
        "W",
        "Warning",
        "Clang emitted this configurable diagnostic as a warning.",
    ),
    (
        "E",
        "Error",
        "Clang emitted this configurable diagnostic as an error, usually "
        "because warning escalation promoted it.",
    ),
    (
        "F",
        "Fatal",
        "Clang emitted this configurable diagnostic as a fatal error.",
    ),
    (
        "R",
        "Remark",
        "Clang emitted this configurable diagnostic as a compilation remark.",
    ),
)


@dataclass
class Allocation:
    name: str
    number: int
    removed: bool = False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate stable Bxxxx Clang diagnostic mappings."
    )

    parser.add_argument(
        "--input",
        type=Path,
        help="File containing one Clang warning-group name per line. "
             "Defaults to stdin.",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        required=True,
        help="Persistent TOML allocation manifest.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="Generated .diag.toml output path.",
    )
    parser.add_argument(
        "--width",
        type=int,
        default=4,
        help="Numeric code width. Defaults to 4.",
    )
    parser.add_argument(
        "--lookup-output",
        type=Path,
        required=True,
        help="Generated Kairo Clang diagnostic lookup file.",
    )

    return parser.parse_args()


def normalize_group(raw: str) -> str | None:
    group = raw.strip()

    if not group or group.startswith("//"):
        return None

    # Accept either the normalized helper output:
    #     unused-variable
    #
    # or raw getDiagnosticFlags() output:
    #     -Wunused-variable
    #     -Wno-unused-variable
    if group in {"-W", "-Wno-"}:
        return None

    if group.startswith("-Wno-"):
        group = group[len("-Wno-") :]
    elif group.startswith("-W"):
        group = group[len("-W") :]

    group = group.strip()

    if not group:
        return None

    if "\x00" in group or "\n" in group or "\r" in group:
        raise ValueError(f"invalid Clang warning group: {raw!r}")

    return group


def read_groups(path: Path | None) -> list[str]:
    if path is None:
        source: Iterable[str] = sys.stdin
    else:
        source = path.read_text(encoding="utf-8").splitlines()

    groups: set[str] = set()

    for line in source:
        group = normalize_group(line)
        if group is not None:
            groups.add(group)

    if not groups:
        raise RuntimeError("no Clang warning groups were provided")

    return sorted(groups)


def load_manifest(path: Path) -> dict[str, Allocation]:
    if not path.exists():
        return {}

    with path.open("rb") as file:
        root = tomllib.load(file)

    raw_groups = root.get("groups", {})
    if not isinstance(raw_groups, dict):
        raise ValueError("manifest key 'groups' must be a TOML table")

    allocations: dict[str, Allocation] = {}
    used_numbers: dict[int, str] = {}

    for name, raw_entry in raw_groups.items():
        if not isinstance(raw_entry, dict):
            raise ValueError(
                f"manifest entry groups.{name!r} must be a TOML table"
            )

        number = raw_entry.get("number")
        removed = raw_entry.get("removed", False)

        if not isinstance(number, int):
            raise ValueError(
                f"manifest entry groups.{name!r}.number must be an integer"
            )

        if not isinstance(removed, bool):
            raise ValueError(
                f"manifest entry groups.{name!r}.removed must be a boolean"
            )

        if number < MIN_NUMBER or number > MAX_NUMBER:
            raise ValueError(
                f"manifest number {number} for {name!r} is outside "
                f"{MIN_NUMBER}..{MAX_NUMBER}"
            )

        previous = used_numbers.get(number)
        if previous is not None:
            raise ValueError(
                f"manifest number {number} is assigned to both "
                f"{previous!r} and {name!r}"
            )

        used_numbers[number] = name
        allocations[name] = Allocation(
            name=name,
            number=number,
            removed=removed,
        )

    return allocations


def update_allocations(
    current_groups: list[str],
    allocations: dict[str, Allocation],
) -> tuple[dict[str, Allocation], list[Allocation]]:
    current_set = set(current_groups)
    used_numbers = {entry.number for entry in allocations.values()}

    # Existing entries retain their numbers. Entries that have returned after
    # being absent are reactivated using their original allocation.
    for name, entry in allocations.items():
        entry.removed = name not in current_set

    next_number = MIN_NUMBER

    def allocate_number() -> int:
        nonlocal next_number

        while next_number in used_numbers:
            next_number += 1

        if next_number > MAX_NUMBER:
            raise RuntimeError(
                f"exhausted {PREFIX}{MIN_NUMBER:04d}.."
                f"{PREFIX}{MAX_NUMBER:04d} diagnostic namespace"
            )

        result = next_number
        used_numbers.add(result)
        next_number += 1
        return result

    added: list[Allocation] = []

    for name in current_groups:
        existing = allocations.get(name)

        if existing is not None:
            existing.removed = False
            continue

        entry = Allocation(
            name=name,
            number=allocate_number(),
            removed=False,
        )

        allocations[name] = entry
        added.append(entry)

    return allocations, added


def toml_quote(value: str) -> str:
    escaped = (
        value
        .replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\b", "\\b")
        .replace("\t", "\\t")
        .replace("\n", "\\n")
        .replace("\f", "\\f")
        .replace("\r", "\\r")
    )
    return f'"{escaped}"'


def code_for(number: int, width: int) -> str:
    return f"{PREFIX}{number:0{width}d}"


def render_manifest(
    allocations: dict[str, Allocation],
    width: int,
) -> str:
    ordered = sorted(
        allocations.values(),
        key=lambda entry: entry.number,
    )

    lines = [
        "# Stable Clang warning-group to Kairo diagnostic-code allocations.",
        "#",
        "# This file is persistent ABI state.",
        "# Never renumber entries and never reuse removed numbers.",
        "",
        "version = 1",
        f'prefix = "{PREFIX}"',
        f"width = {width}",
        "",
    ]

    for entry in ordered:
        lines.append(f"[groups.{toml_quote(entry.name)}]")
        lines.append(f"number = {entry.number}")

        if entry.removed:
            lines.append("removed = true")

        lines.append("")

    return "\n".join(lines)


def explain_for(group: str, severity_description: str) -> str:
    return (
        f"{severity_description} This diagnostic is controlled by Clang's "
        f"'-W{group}' warning option. Consult the Clang diagnostics "
        f"documentation for the exact meaning and triggering conditions of "
        f"'{group}'."
    )


def render_diag_toml(
    allocations: dict[str, Allocation],
    width: int,
) -> str:
    active = sorted(
        (
            entry
            for entry in allocations.values()
            if not entry.removed
        ),
        key=lambda entry: entry.number,
    )

    lines = [
        "# -------------------------------------------------------------------------",
        "# Auto-generated Clang backend diagnostic table.",
        "#",
        "# Generated from the stable allocation manifest.",
        "# Do not assign or change codes manually in this file.",
        "# -------------------------------------------------------------------------",
        "",
    ]

    for entry in active:
        base_code = code_for(entry.number, width)
        warning_option = f"-W{entry.name}"

        lines.append(f"[{base_code}]")
        lines.append(
            f"brief = {toml_quote(f'Clang diagnostic {warning_option}')}"
        )
        lines.append(f"group = {toml_quote('Clang')}")

        for severity_code, _, severity_description in SEVERITIES:
            full_explanation = explain_for(
                entry.name,
                severity_description,
            )

            lines.append(f"    [{base_code}.{severity_code}]")
            lines.append(
                f"    explain = {toml_quote(full_explanation)}"
            )

        lines.append("")

    return "\n".join(lines)


def write_if_changed(path: Path, contents: str) -> bool:
    normalized = contents.rstrip() + "\n"

    if path.exists():
        existing = path.read_text(encoding="utf-8")
        if existing == normalized:
            return False

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(normalized, encoding="utf-8")
    return True


def kairo_string(value: str) -> str:
    return (
        value
        .replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )


def render_lookup_k(
    allocations: dict[str, Allocation],
) -> str:
    active = sorted(
        (
            entry
            for entry in allocations.values()
            if not entry.removed
        ),
        key=lambda entry: entry.number,
    )

    lines = [
        "/// --- The Kairo Project -------------------------------------------------- ///",
        "///",
        "/// Auto-generated by Scripts/gen_clang_diag_table.py.",
        "/// Do not edit manually.",
        "///",
        "/// ------------------------------------------------------------------------ ///",
        "",
        "import Support::EvalHash::*;",
        "",
        "eval fn clang_diag_number(group: string) -> u32 {",
        "    var h = compute_hash(&group);",
        "",
        "    switch h {",
    ]

    for entry in active:
        name = kairo_string(entry.name)

        lines.extend([
            f'        case compute_hash::<r"{name}">() {{',
            f'            return ({entry.number}) if group == "{name}" else 0;',
            "        }",
        ])

    lines.extend([
        "    }",
        "",
        "    return 0;",
        "}",
        "",
        "eval fn clang_diag_group(number: u32) -> string {",
        "    switch number {",
    ])

    for entry in active:
        name = kairo_string(entry.name)
        lines.append(
            f'        case {entry.number} {{ return "{name}"; }}'
        )

    lines.extend([
        "    }",
        "",
        '    return "";',
        "}",
    ])

    return "\n".join(lines)

def main() -> int:
    args = parse_args()

    if args.width < 1:
        print("ERROR: --width must be at least 1", file=sys.stderr)
        return 1

    if args.width != 4:
        print(
            "WARNING: the backend namespace currently requires four digits; "
            f"requested width is {args.width}",
            file=sys.stderr,
        )

    try:
        current_groups = read_groups(args.input)
        allocations = load_manifest(args.manifest)
        allocations, added = update_allocations(
            current_groups,
            allocations,
        )

        manifest = render_manifest(allocations, args.width)
        diag_toml = render_diag_toml(allocations, args.width)
        lookup_k = render_lookup_k(allocations)

        manifest_changed = write_if_changed(args.manifest, manifest)
        output_changed = write_if_changed(args.output, diag_toml)
        lookup_changed = write_if_changed(args.lookup_output, lookup_k)

        active_count = sum(
            1 for entry in allocations.values() if not entry.removed
        )
        removed_count = sum(
            1 for entry in allocations.values() if entry.removed
        )

        print(
            f"Clang groups: {active_count} active, "
            f"{len(added)} newly allocated, "
            f"{removed_count} tombstoned",
            file=sys.stderr,
        )
        print(
            f"Manifest: {'updated' if manifest_changed else 'unchanged'} "
            f"({args.manifest})",
            file=sys.stderr,
        )
        print(
            f"Diagnostic table: "
            f"{'updated' if output_changed else 'unchanged'} "
            f"({args.output})",
            file=sys.stderr,
        )

        print(
            f"Lookup table: "
            f"{'updated' if lookup_changed else 'unchanged'} "
            f"({args.lookup_output})",
            file=sys.stderr,
        )

        if added:
            print("New allocations:", file=sys.stderr)
            for entry in sorted(added, key=lambda item: item.number):
                print(
                    f"  {code_for(entry.number, args.width)} "
                    f"-> -W{entry.name}",
                    file=sys.stderr,
                )

    except (OSError, RuntimeError, ValueError, tomllib.TOMLDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())