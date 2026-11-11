#!/usr/bin/env python3
"""Check that the AST serializer names every field of every node class.

Compiler/AST/Serialize has one `io_` function per node class, and the rule
those functions are written to (DeclIO.k's header) is that every field of
the class is either stored through an archive primitive or named in the
function's DEBUG block, where the writer checks a later stage has not set
it. Nothing in the language enforces the rule: a field added to a node and
forgotten here is silently lost on reload, and the round-trip gate only
sees it when a test happens to depend on it. This script is the enforcement.

It reads the field declarations of the node files (Compiler/AST/Node/*.k,
the mixins, DeclContext) and fails when a field's name does not occur in
the `io_` function(s) of its class. "Occurs" is by name, in code or in a
check's message string ("FunctionDecl::panic_eff"), which is exactly how
the two ways of naming a field look; a mention in a comment does not count.

Deliberate exceptions are tables below, each entry with its reason:

  REFUSED   classes the serializer does not write at all (Sema's objects)
  REBUILT   fields the reader recomputes from the tree
  NOT_AST   structs in the node files that are not part of a node

Usage:  python3 Scripts/check_ast_serializer.py        (exit 1 on a miss)
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AST = os.path.join(REPO, "Compiler", "AST")
SER = os.path.join(AST, "Serialize")

NODE_FILES = [
    "Node/Base.k", "Node/Declarations.k", "Node/Expressions.k",
    "Node/PrimaryExpressions.k", "Node/Statements.k", "Node/Types.k",
    "Node/CanonicalNodes.k", "Node/Patterns.k",
    "Mixin/Annotation.k", "Mixin/FFILinkage.k", "Mixin/Redeclarable.k",
    "Mixin/TemplateParams.k", "Mixin/TypeQual.k", "Context/DeclContext.k",
]

# Classes with no io_ function, and why.
REFUSED = {
    "QualifiedType": "canonical type: build-wide, interned by Sema",
    "BuiltinType": "canonical type: build-wide, interned by Sema",
    "RecordType": "canonical type: names a declaration of any file",
    "AssocType": "canonical type: build-wide, interned by Sema",
    "SubstGenericParamType": "made by Sema's substitution around a canonical type",
    "VariantInitExpr": "minted by VariantInitLowering around a resolved enum declaration",
}

# Structs declared in the node files that no parsed node holds.
NOT_AST = {
    "Requirement": "InterfaceDecl::requirements, written by InterfaceComposition",
    "FormatHole": "StringLiteralExpr::fmt_holes, written by X",
    "ForeignLayout": "FFILinkage::layout, written by Sema/Foreign",
    "FloatLayout": "a builtin type's description, not a node",
    "BuiltinInfo": "a builtin type's description, not a node",
}

# Fields the reader restores by recomputing them, per class.
REBUILT = {
    "DeclContext": {
        "dc_scope": "ASTParse::rebuild_derived (_wire_scopes)",
        "dc_symbols": "ASTParse::rebuild_derived (_build_symbols)",
    },
    # The family header writes these two for every node; no io_ function of
    # a class needs to.
    "*": {
        "kind": "family header",
        "range": "family header",
        "recovery_kind": "family header",
    },
}

# Where a class's fields are named when it is not io_<snake_case(class)>.
FUNCTIONS = {
    "Expr": ["io_expr_base"],
    "Stmt": ["io_stmt_base"],
    "Decl": ["io_decl_base"],
    "Type": ["io_type_base"],
    "Pattern": ["io_pattern_base"],
    "VisibilityAnnotation": ["io_decl_base"],
    "Annotation": ["io_annotations"],
    "AnnotationEntry": ["io_annotations"],
    "TypeQual": ["io_type_base"],
    "ExtQuals": ["io_type_base"],
    "QualSpan": ["io_type_base"],
    "DeclContext": ["io_dc"],
    "Redeclarable": ["io_redecl"],
    "TemplateParams": ["io_template_params"],
    "FFILinkage": ["io_ffi"],
    "InheritEdge": ["io_inherit_edges"],
    "IntConst": ["io_enum_variant_decl"],
    "ImportItem": ["io_import_decl"],
    "MacroParamSpec": ["io_macro_decl"],
    "MapLiteralExpr::Entry": ["io_map_literal_expr"],
    "InitField": ["io_init_fields"],
    "IfExpr::ElseIf": ["io_if_expr"],
    "TryCatchExpr::CatchArm": ["io_try_catch_expr"],
    "ClosureExpr::Capture": ["io_closure_expr"],
    "ChainExpr::Step": ["io_chain_expr"],
    "Binding": ["io_bindings"],
    "CatchArm": ["io_try_catch_stmt"],
    "DispatchCase": ["io_switch_dispatch_stmt"],
    "MatchCase": ["io_match_cases"],
    "ChainType::GenericArg": ["io_generic_arg"],
    "ChainType::ChainSegment": ["io_chain_type"],
    "CXXLValueRefType": ["io_cxx_lvalue_ref_type"],
    "CXXRValueRefType": ["io_cxx_rvalue_ref_type"],
    "OpaqueFFIType": ["io_opaque_ffi_type"],
}

CLASS_RE = re.compile(r"^\s*(?:pub\s+)?(class|struct)\s+(?:<[^>]*>\s*)?(\w+)")
FIELD_RE = re.compile(r"^\s*(?:pub\s+|priv\s+|prot\s+)?var\s+(\w+)\s*:")
FN_RE = re.compile(r"^(?:pub\s+)?fn\s+(?:<[^>]*>\s*)?(io_\w+)\s*\(")


def strip_comment(line):
    at = line.find("//")
    return line if at < 0 else line[:at]


def read_classes():
    """{qualified class name: [(field, file, line)]} from the node files."""
    classes = {}
    for rel in NODE_FILES:
        path = os.path.join(AST, rel)
        stack = []  # (name, depth at which its body opened)
        depth = 0
        lines = open(path, encoding="utf-8").read().split("\n")
        i = 0
        while i < len(lines):
            code = strip_comment(lines[i])
            m = CLASS_RE.match(code)
            if m:
                header = code
                j = i
                while "{" not in header and j + 1 < len(lines):
                    j += 1
                    header += " " + strip_comment(lines[j])
                name = "::".join([s[0] for s in stack] + [m.group(2)])
                classes[name] = []
                stack.append((m.group(2), depth))
                depth += header.count("{") - header.count("}")
                i = j + 1
                continue
            if stack and depth == stack[-1][1] + 1:
                f = FIELD_RE.match(code)
                if f:
                    name = "::".join(s[0] for s in stack)
                    classes[name].append((f.group(1), rel, i + 1))
            depth += code.count("{") - code.count("}")
            while stack and depth <= stack[-1][1]:
                stack.pop()
            i += 1
    return classes


def read_functions():
    """{io function name: its text} from the serializer's files."""
    functions = {}
    for name in sorted(os.listdir(SER)):
        if not name.endswith(".k"):
            continue
        lines = open(os.path.join(SER, name), encoding="utf-8").read().split("\n")
        i = 0
        while i < len(lines):
            m = FN_RE.match(lines[i])
            if not m:
                i += 1
                continue
            j = i
            while not lines[j].startswith("}"):
                j += 1
            # Comments are dropped: a field mentioned only in prose is not a
            # field the function stores or checks.
            functions[m.group(1)] = "\n".join(strip_comment(l) for l in lines[i:j + 1])
            i = j + 1
    return functions


def snake(name):
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", "_", name).lower()


def main():
    classes = read_classes()
    functions = read_functions()

    missing = []
    checked_classes = checked_fields = 0
    for cls in sorted(classes):
        leaf = cls.split("::")[-1]
        if cls in REFUSED or leaf in REFUSED or cls in NOT_AST:
            continue
        names = FUNCTIONS.get(cls) or ["io_" + snake(leaf)]
        texts = [functions[n] for n in names if n in functions]
        if not texts:
            if classes[cls]:
                missing.append("%s: no %s in Compiler/AST/Serialize" % (cls, " / ".join(names)))
            continue
        checked_classes += 1
        text = "\n".join(texts)
        rebuilt = dict(REBUILT["*"]) if cls not in ("Expr", "Stmt", "Decl", "Type", "Pattern") else {}
        rebuilt.update(REBUILT.get(cls, {}))
        for field, rel, line in classes[cls]:
            if field in rebuilt:
                continue
            checked_fields += 1
            if not re.search(r"\b%s\b" % re.escape(field), text):
                missing.append("%s::%s (Compiler/AST/%s:%d) is not named in %s"
                               % (cls, field, rel, line, " / ".join(names)))

    for line in missing:
        print("check_ast_serializer: " + line)
    print("check_ast_serializer: %d classes, %d fields checked, %d refused classes, %d missing"
          % (checked_classes, checked_fields, len(REFUSED), len(missing)))
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
