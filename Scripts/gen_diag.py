#!/usr/bin/env python3
"""
Reads the *.diag.toml files and writes the diagnostic registry as Stage 1 Kairo:

  --output       Compiler/Diagnostic/Registry.k: DiagID and the declarations of
                 diag_meta / diag_explain / diag_from_string / Diag::<cat>. What every
                 compiler file imports.
  --full-output  the same declarations plus every body, as ONE module. build.py
                 compiles it with the compiler doing the build into the registry object
                 and puts its root first on the include path, so for that one compile it
                 shadows the declarations-only file.

Usage:
    python3 Scripts/gen_diag.py Compiler/Diagnostic/TableGen \
        --output=Compiler/Diagnostic/Registry.k --full-output=build/registry/Compiler/Diagnostic/Registry.k

DiagID values are compute_hash::<"CODE">() folded at generation time
(Scripts/Migration/eval_hash.py, the same function as Support/EvalHash.k), so the enum
needs no compile-time evaluation. A file is rewritten only when its text changes, so an
unchanged TOML set leaves build.py's registry stamp valid.
"""

import sys, tomllib, textwrap, os, argparse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "Migration"))
from eval_hash import compute_hash, FNV_OFFSET_BASIS, FNV_PRIME, GOLDEN_RATIO_MIX, RESERVED_LOW  # noqa: E402

CAT_MAP = {
    "S": "Syntax", "U": "Uncategorized", "C": "CodeGen",
    "M": "Memory", "R": "Resolution", "L": "Linker",
    "SC": "Semantic", "P": "Portability", "CL": "Lowering",
    "OPT": "Optimization", "I": "Internal"
}
SEV_MAP = {
    "I": "Ignored", "R": "Remark", "V": "Verbose",
    "N": "Note", "D": "Debug", "W": "Warning",
    "E": "Error", "F": "Fatal",
}

def parse_base_code(code: str):
    for prefix in sorted(CAT_MAP.keys(), key=len, reverse=True):
        if code.startswith(prefix):
            num = code[len(prefix):]
            return prefix, CAT_MAP[prefix], int(num)
    raise ValueError(f"bad code: {code}")


def parse_args():
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("folder")
    p.add_argument("--output", required=True,
                   help="the declarations-only registry, Compiler/Diagnostic/Registry.k")
    p.add_argument("--full-output",
                   help="the declarations plus bodies, compiled by build.py into the registry object")
    return p.parse_args()


def load_diags(folder):
    merged_toml = ""
    toml_files = sorted(os.path.join(folder, f) for f in os.listdir(folder) if f.endswith(".diag.toml"))
    for toml_file in toml_files:
        with open(toml_file, "rb") as f:
            merged_toml += f.read().decode("utf-8") + "\n"

    data = tomllib.loads(merged_toml)

    diags = []
    seen = set()
    seen_ident = {}

    for base_code, entry in data.items():
        if not isinstance(entry, dict):
            print(f"ERROR: expected table for '{base_code}'", file=sys.stderr)
            sys.exit(1)

        prefix, cat, num = parse_base_code(base_code)
        brief = entry.get("brief", "")
        group = entry.get("group", "")

        for sev_char, sev_entry in entry.items():
            if sev_char in ("brief", "group"):
                continue
            if sev_char not in SEV_MAP:
                print(f"ERROR: unknown key '{sev_char}' in {base_code}", file=sys.stderr)
                sys.exit(1)
            if not isinstance(sev_entry, dict):
                print(f"ERROR: expected table for '{base_code}.{sev_char}'", file=sys.stderr)
                sys.exit(1)

            full_code = f"{base_code}{sev_char}"
            if full_code in seen:
                print(f"ERROR: duplicate {full_code}", file=sys.stderr)
                sys.exit(1)
            seen.add(full_code)
            # A code is its category, number and severity; the key's zero
            # padding is only spelling (C0195 prints as C195). Two keys that
            # differ in padding alone would be one code to --explain and to
            # the -W/-A policy lists, which match on the number.
            ident = (prefix, num, sev_char)
            if ident in seen_ident:
                print(f"ERROR: {full_code} duplicates {seen_ident[ident]} (same category, number and severity)", file=sys.stderr)
                sys.exit(1)
            seen_ident[ident] = full_code

            explain = textwrap.dedent(sev_entry.get("explain", "")).strip()
            diags.append((full_code, cat, num, SEV_MAP[sev_char], brief, group, explain))

    return diags, merged_toml


def license_header():
    return [
        "/// --- The Kairo Project ------------------------ Diagnostic/Registry.k --- ///",
        "///",
        "///   The diagnostic registry, generated from Diagnostic/TableGen/*.diag.toml:",
        "///   every DiagID with its code, severity, message and explain text.",
        "///",
        "///   Part of the Kairo Project, under the Apache License v2.0 with the",
        "///   Kairo Runtime Library Exception.",
        "///",
        "///   See: https://www.kairolang.org/LICENSE",
        "///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception",
        "///   Copyright (c) 2026 Dhruvan Kartik",
        "///",
        "/// ------------------------------------------------------------------------ ///",
        "",
    ]


def autogen_banner():
    return [
        "////////////////////////////////////////////////////////////////////////////////",
        "///--------------------------------------------------------------------------///",
        "/// This file is auto-generated by Scripts/gen_diag.py. Do NOT edit manually ///",
        "///--------------------------------------------------------------------------///",
        "////////////////////////////////////////////////////////////////////////////////",
        "",
    ]


def hashed(code):
    return f'{compute_hash(code)} /* "{code}" */'


def kairo_imports(uses):
    """Kairo import lines for {module path: [names]}, in the formatter's layout
    (Extras/Formatter/README rules 5.1-5.4): sorted by path; one name is
    `import A::b;`; two to six names, or any long one, are the block form, one
    per line with a trailing comma and no `;` after the `}`; more than six
    short names are the grid form, column-aligned rows under the 80-column
    width. Only names the generated code uses: a wildcard would import a
    module's whole surface into a 65k-line file for three of its names."""
    width, indent, short = 80, 4, 24
    out = []
    for path in sorted(uses):
        names = sorted(set(uses[path]))
        if len(names) == 1:
            out.append(f"import {path}::{names[0]};")
            continue
        out.append(f"import {path}::{{")
        if len(names) <= 6 or any(len(n) > short for n in names):
            out += [f"{' ' * indent}{n}," for n in names]
        else:
            cells = [f"{n}," for n in names]
            col = max(len(c) for c in cells) + 1
            per_row = max(1, (width - indent) // col)
            for i in range(0, len(cells), per_row):
                row = cells[i:i + per_row]
                out.append(" " * indent + "".join(c.ljust(col) for c in row[:-1]) + row[-1])
        out.append("}")
    return out


def gen_decls(diags, extra_uses=None, ffi_imports=()):
    """DiagID, then the declarations. Shared verbatim by both outputs, but for
    the imports: the bodies name more (DiagCategory) and need the C++ header,
    and an `ffi` import goes first (rule 5.3)."""
    uses = {"Diagnostic::Meta": ["DiagMeta"], "Diagnostic::Severity": ["DiagSeverity"]}
    for path, names in (extra_uses or {}).items():
        uses.setdefault(path, []).extend(names)
    lines = []
    lines += license_header()
    lines += autogen_banner()
    if ffi_imports:
        lines += [*ffi_imports, ""]
    lines += kairo_imports(uses)
    lines += [
        "",
        # @open: diag_from_string casts any hash to DiagID, and an unknown code's hash
        # names no variant.
        "@open pub enum DiagID derives u32 {",
        "  Invalid = 0,",
    ]
    for code, *_ in diags:
        lines.append(f"  {code} = {hashed(code)},")
    lines += [
        "}",
        "",
        "pub fn diag_meta(id: DiagID) -> DiagMeta;",
        "pub fn diag_explain(id: DiagID) -> string;",
        "pub fn diag_from_string(code_str: string) -> DiagID;",
        "",
        "pub module Diag {",
    ]
    for prefix in CAT_MAP:
        lines.append(f"  pub fn {prefix}(num: u32, sev: DiagSeverity) -> DiagID;")
    lines.append("}")
    return lines


def escape(text, quote=True):
    """A string-literal body. `'` needs no escape in a "..." literal; explain text
    escapes it anyway (as Stage 0 did), brief/group text does not."""
    if not quote:
        return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return (text.replace("\\", "\\\\").replace('"', '\\"').replace("'", "\\'")
            .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
            .replace("\0", "\\0").replace("\x0b", "\\v").replace("\x1b", "\\e"))


def gen_registry(diags):
    return "\n".join(gen_decls(diags)) + "\n"


def gen_full_registry(diags):
    lines = gen_decls(diags, {"Diagnostic::Category": ["DiagCategory"]}, ['ffi "c++" import "Native/Types.hh";'])
    lines += ["", "", "/// # Bodies", ""]

    lines.append("pub fn diag_meta(id: DiagID) -> DiagMeta {")
    lines.append("  match id {")
    lines.append("    case DiagID::Invalid { return DiagMeta{}; }")
    for code, cat, num, sev, brief, group, _ in diags:
        lines += [
            f"    case DiagID::{code} {{",
            "      return DiagMeta{",
            f'        brief: "{escape(brief, False)}",',
            f'        group: "{escape(group, False)}",',
            f"        number: {num},",
            f"        hash: ({hashed(code)} as u32),",
            f"        category: DiagCategory::{cat},",
            f"        severity: DiagSeverity::{sev}",
            "      };",
            "    }",
        ]
    # A value no variant names (diag_from_string's hash of an unknown code; DiagID is
    # @open) takes the default.
    lines += ["    default { return DiagMeta{}; }", "  }", "  return DiagMeta{};", "}", ""]

    lines.append("pub fn diag_explain(id: DiagID) -> string {")
    lines.append("  match id {")
    lines.append('    case DiagID::Invalid { return ""; }')
    for code, _, _, _, _, _, explain in diags:
        lines.append(f'    case DiagID::{code} {{ return "{escape(explain)}"; }}')
    lines += ['    default { return ""; }', "  }", '  return "";', "}", ""]

    # DiagID derives u32 and the hash is u64: a cast to an enum is only from its
    # underlying type (SC127E), so narrow first.
    #
    # The hash is EvalHash.k's run-time compute_hash(*const string), written out rather
    # than called: build.py links this object into EVERY tool, and kld /
    # clang-diag-identity / katar never compile EvalHash.k, so a call left an undefined
    # symbol. The object may reference nothing a tool's own graph does not define.
    # Constants from eval_hash.py, the Python copy every variant's value comes from.
    # Wrapping u64 arithmetic, as in EvalHash.k; an empty spelling is HASH_MAX there.
    lines += [
        "pub fn diag_from_string(code_str: string) -> DiagID {",
        "  const len: usize = code_str.length();",
        "  if len == 0 { return (0xFFFFFFFF as u32) as DiagID; }",
        f"  var h: u64 = {FNV_OFFSET_BASIS:#x};",
        "  for var i: usize = 0; i < len; ++i {",
        "    h = h ^ ((code_str[i] as u8) as u64);",
        f"    h = h * {FNV_PRIME:#x};",
        "    h = h ^ (i as u64);",
        "  }",
        f"  h = (h ^ ((len as u64) * {GOLDEN_RATIO_MIX:#x})) + {RESERVED_LOW:#x};",
        "  return (((h >> 32) ^ h) as u32) as DiagID;",
        "}",
        "",
    ]

    lines.append("pub module Diag {")
    for prefix, cat in CAT_MAP.items():
        lines.append(f"  pub fn {prefix}(num: u32, sev: DiagSeverity) -> DiagID {{")
        lines.append("    match sev {")
        for sev_name in SEV_MAP.values():
            lines.append(f"      case DiagSeverity::{sev_name} {{")
            lines.append("        match num {")
            for code, c, n, s, _, _, _ in diags:
                if c == cat and s == sev_name:
                    lines.append(f"          case {n} {{ return DiagID::{code}; }}")
            lines.append(f'          default {{ kairo::std::ice_fail("invalid diag number for {prefix} and severity {sev_name}"); }}')
            lines.append("        }")
            lines.append("      }")
        lines.append('      default { kairo::std::ice_fail("invalid diag severity"); }')
        lines.append("    }")
        lines.append(f'    kairo::std::ice_fail("reached unreachable code in Diag::{prefix}");')
        lines.append("    return DiagID::Invalid; // unreachable")
        lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def write_if_changed(path, text):
    path = Path(path)
    if path.exists() and path.read_text(encoding="utf-8") == text:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)
    return True


def main():
    args = parse_args()
    diags, _ = load_diags(args.folder)
    write_if_changed(args.output, gen_registry(diags))
    if args.full_output:
        write_if_changed(args.full_output, gen_full_registry(diags))


if __name__ == "__main__":
    main()