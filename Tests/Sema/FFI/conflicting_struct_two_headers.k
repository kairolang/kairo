// Two C headers define one struct name differently (`struct Pt { int x; }`
// in ha.h, `struct Pt { double y; }` in hb.h), each imported by its own
// module. Kairo identifies a C entity by its USR, so both are one 'Pt', and
// the second definition's members would land in the scope the first header has
// already frozen ("SymbolTable::append after freeze" in a debug build),
// or in a release build graft a 'y' onto ha.h's Pt that Sema accepts
// and clang rejects at codegen. So the conflict is an error at the
// second definition, naming the member that is not imported, with a note at
// the definition Kairo keeps. Two IDENTICAL definitions (ha.h and hc.h) are
// one entity and stay silent.

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo -I %S/Inputs/conflicting_struct %S/Inputs/conflicting_struct/main.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIFF
// DIFF-NOT: Internal Compiler Error
// DIFF: hb.h:1:21: error [R001E]: 'Pt' is defined differently by two imported headers: Kairo keeps one 'Pt', so 'y' of this definition is not imported
// DIFF-NEXT: ha.h:1:9: note [I900N]: the definition of 'Pt' Kairo uses; one program sees one definition of each C/C++ entity, so give one of the two a different name
// DIFF-NOT: Internal Compiler Error

// RUN: { %kairo -I %S/Inputs/conflicting_struct %S/Inputs/conflicting_struct/main_same.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=SAME --allow-empty
// SAME-NOT: error
