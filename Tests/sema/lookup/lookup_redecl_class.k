// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Ported from (semantic content only):
//   Lib/llvm-runtimes/clang/test/SemaCXX/struct-class-redecl.cpp
//   Lib/llvm-runtimes/clang/test/SemaCXX/typedef-redecl.cpp (the "same name,
//   redeclared as a different KIND of entity" half only)
//
// clang's struct-class-redecl.cpp is almost entirely about `class Foo` vs
// `struct Foo` tag mismatches -- a warning, not an error, and driven by
// elaborated-type-specifier machinery Kairo does not have (Kairo's `class`
// and `struct` are genuinely different DeclKinds with no shared "tag", so
// there is no elaborated-tag-mismatch concept to port). What DOES carry
// over, and is real N(a) behavior (RESOLUTION.md §2.5(a)): a forward
// declaration followed by its definition is ONE redecl chain, not a
// redefinition; two full definitions of the same name (class/class,
// regardless of tag) IS a redefinition; and the same spelling declared as
// two fundamentally different KINDS of entity (a class and a var) is a
// separate diagnosis path ("declared with conflicting kinds") from a
// same-kind redefinition ("redefinition of").
//
// Dropped: struct-vs-class tag mismatch warnings (no shared tag concept),
// template forward-decl-as-wrong-kind cases (needs OverloadResolution /
// M1, both [MISSING] per RESOLUTION.md §4), and struct forward declarations
// specifically -- Kairo's parser only accepts a bodyless forward decl for
// `class` (`class Foo;`); `struct Foo;` is a parse error (DeclParse.k has
// no forward-decl path for structs), so CASE 1 uses `class` only.

// ---------------------------------------------------------------------------
// CASE 1: forward declaration + definition. ONE redecl chain; canonical is
// the DEFINITION, not the first-seen forward decl. Not an error.

class Shape;

class Shape {
    var side: i32;
}

fn use_shape(s: Shape) -> i32 { return s.side }

// ---------------------------------------------------------------------------
// CASE 2: two FULL definitions of the same name, same kind. This is a
// redefinition (not a chain): the second definition is poisoned, and the
// diagnostic names both locations.

class FullDup {
    var z: i32;
}

class FullDup {
    var w: i32;
}

// ---------------------------------------------------------------------------
// CASE 3: same spelling, two fundamentally different DECL KINDS (a var and
// a class). This is "declared with conflicting kinds", the sibling
// diagnosis to CASE 2's "redefinition of" -- same cell, different code path
// (RESOLUTION.md's `_validate_cell`: `kind_ok` false takes priority over
// the redeclarable-chain path).
//
// NOTE on order: types are hoisted into scope ahead of values (so that a
// function may reference a type declared later in the file), so the CLASS
// decl lands in the symbol cell before the VAR decl regardless of which one
// is written first in the source. The diagnostic's "previous declaration"
// therefore points at the class even though it appears BELOW the var
// textually -- this is intentional hoisting order, not source order.

var Mixed: i32 = 1;
class Mixed {
    var q: i32;
}

// --- expected diagnostics ---------------------------------------------
//
// The two diagnoses (CASE 2, CASE 3) come from independent symbol cells;
// their RELATIVE order is an implementation detail of cell iteration, not
// something this test pins down. Each error/note PAIR is adjacent and in
// that fixed order, checked with CHECK-DAG so either cell may come first.
//
// DIAG-DAG: redefinition of 'FullDup'
// DIAG-DAG: note{{.*}}: previous definition of 'FullDup' is here
// DIAG-DAG: 'Mixed' declared with conflicting kinds
// DIAG-DAG: note{{.*}}: previous declaration of 'Mixed' is here
//
// Nothing else -- CASE 1's chain must not surface as a redefinition.
// DIAG-NOT: redefinition of 'Shape'
// DIAG-NOT: conflicting kinds{{.*}}Shape

// --- bindings ----------------------------------------------------------
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}lookup_redecl_class.k =====

// CASE 1: one chain of two, canonical is the DEFINITION (line 35), not the
// forward decl (line 33).
// SEMA:      <tu>::Shape   [redecl chain x2]
// SEMA-NEXT:   - class Shape @ 33:1
// SEMA-NEXT:   - class Shape @ 35:1  [definition]  [canonical]

// CASE 2/3's errors halt the pipeline at NamesResolved for this TU (T and
// ChainBinding never run when N reports an error), so `use_shape`'s member
// access is not checked here -- that binding is exercised, error-free, by
// lookup_redecl_class's sibling member_base_lookup.k instead. What matters
// here is only that N(a) itself did not mis-classify CASE 1's chain.

// Nothing left unbound (the two redefinitions are poisoned, not unresolved).
// SEMA: 0 unresolved
