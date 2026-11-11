// Macro-expanded code in a serialized AST. A token an expansion produced is
// TkMacroExpand: its `imm` names a chain of MacroExpansionInfo records in
// the expanding file's immediate table, and the token it stands for (a
// name, a literal) lives in the table of the file that WROTE it, which for
// an imported macro is another file's. The format stores the chain and the
// original token's payload by value, and the reader rebuilds both in the
// tables they came from.
//
// What must hold on the reloaded tree:
//   - it is the same tree (--verify-ast-roundtrip: print, bytes, tables);
//   - a program built from it runs the same (main.k: literals, a two-part
//     string and an f-string hole out of lib.k's macros);
//   - a diagnostic against it prints the same location and the same macro
//     backtrace, in both renderers: Sema's errors inside expanded code
//     (sema_bad.k) and the parser's with its `in expansion of` notes
//     (bad.k, whose recovery nodes are built from expanded tokens).
//
// Inputs/macros: main.k, sema_bad.k and bad.k expand lib.k's macros and
// their own.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/macros && %kairo main.k --type-check-only --verify-ast-roundtrip
// RUN: cd %S/Inputs/macros && { %kairo main.k --type-check-only --ast-roundtrip 2>&1 || true; } | %FileCheck %s --check-prefix=CLEAN --allow-empty
// CLEAN-NOT: {{error|warning|fatal}}
//
// RUN: cd %S/Inputs/macros && { %kairo sema_bad.k --type-check-only 2>&1 || true; } > %t.sema.parsed
// RUN: cd %S/Inputs/macros && { %kairo sema_bad.k --type-check-only --ast-roundtrip 2>&1 || true; } > %t.sema.reloaded
// RUN: diff %t.sema.parsed %t.sema.reloaded
// RUN: %FileCheck %s --check-prefix=SEMA < %t.sema.reloaded
// SEMA: sema_bad.k:10:12: error [R020E]: use of undeclared identifier 'no_such_name_here'
// SEMA: sema_bad.k:14:12: error [R020E]: use of undeclared identifier 'no_such_name_in_lib'
//
// RUN: cd %S/Inputs/macros && { %kairo sema_bad.k --type-check-only --error-format=pretty 2>&1 || true; } > %t.pretty.parsed
// RUN: cd %S/Inputs/macros && { %kairo sema_bad.k --type-check-only --error-format=pretty --ast-roundtrip 2>&1 || true; } > %t.pretty.reloaded
// RUN: diff %t.pretty.parsed %t.pretty.reloaded
//
// RUN: cd %S/Inputs/macros && { %kairo bad.k --type-check-only 2>&1 || true; } > %t.bad.parsed
// RUN: cd %S/Inputs/macros && { %kairo bad.k --type-check-only --ast-roundtrip 2>&1 || true; } > %t.bad.reloaded
// RUN: diff %t.bad.parsed %t.bad.reloaded
// RUN: %FileCheck %s --check-prefix=BAD < %t.bad.reloaded
// BAD: bad.k:4:25: error [S053E]: expected type, found '='
// BAD: bad.k:5:18: note [I900N]: in expansion of macro 'inner!()' invoked here
// BAD: bad.k:7:17: note [I900N]: in expansion of macro 'outer!()' invoked here
// RUN: cd %S/Inputs/macros && { %kairo bad.k --syntax-only --verify-ast-roundtrip 2>&1 || true; } | %FileCheck %s --check-prefix=VERIFY
// VERIFY-NOT: I002F
// VERIFY: error [S053E]
// RUN: cd %S/Inputs/macros && { %kairo bad.k --syntax-only --print-ast=tree 2>/dev/null || true; } > %t.tree.parsed
// RUN: cd %S/Inputs/macros && { %kairo bad.k --syntax-only --print-ast=tree --ast-roundtrip 2>/dev/null || true; } > %t.tree.reloaded
// RUN: diff %t.tree.parsed %t.tree.reloaded

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: cd %S/Inputs/macros && %kairo main.k --ast-roundtrip -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out; test $? -eq 0
// RUN: %FileCheck %s --check-prefix=OUT < %t.out
// OUT:      abcd
// OUT-NEXT: v=42
