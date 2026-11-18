// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// No direct clang analogue -- C++ has exactly one member-access spelling
// for a given left-hand side (`.` for a value, `->` for a pointer, `::`
// for a type/namespace, chosen by GRAMMAR not by a semantic pass), so
// there is no clang regression test that exists to catch "wrong
// separator" as a SEMANTIC error the way Kairo does. Kairo's chain syntax
// (`.`, `->`, `?.`, `?->`, `::` are all valid tokens after ANY chain step
// syntactically) pushes that check into ChainBinding instead: RESOLUTION.md
// §2.7, "Module -> `::`... `.` is an error; Type -> `::`... `.` is an
// error ('use ::'); Value -> `.`/`->`/`?.`/`?->`... `::` is an error." This
// file is a from-scratch suite for that Kairo-native rule set, included
// because it is squarely ChainBinding member-resolution territory and
// directly exercises the "one error, one home" invariant (RESOLUTION.md
// §3.3: "no member / wrong separator / member ambiguity: ChainBinding").
//
// Dropped: nothing ported, nothing dropped -- there is no clang source to
// diff against for this file's content.

class Foo {
    pub { var v: i32; }
}

// ---------------------------------------------------------------------------
// CASE 1 (negative): `::` after a VALUE anchor.
fn bad_colon_on_value(f: Foo) -> i32 { return f::v }

// ---------------------------------------------------------------------------
// CASE 2 (negative): `.` after a TYPE anchor.
fn bad_dot_on_type() -> i32 { return Foo.v }

// ---------------------------------------------------------------------------
// CASE 3 (negative): `->` on a non-pointer value.
fn bad_arrow_on_value(f: Foo) -> i32 { return f->v }

// ---------------------------------------------------------------------------
// CASE 4 (negative): `.` on a pointer (must use `->`).
fn bad_dot_on_pointer(p: *Foo) -> i32 { return p.v }

// ---------------------------------------------------------------------------
// CASE 5 (positive): `->` on a pointer -- the correct pairing for CASE 4.
fn ok_arrow_on_pointer(p: *Foo) -> i32 { return p->v }

// ---------------------------------------------------------------------------
// CASE 6 (positive): `.` on an ordinary value -- the correct pairing for
// CASE 1 and CASE 3.
fn ok_dot_on_value(f: Foo) -> i32 { return f.v }

// ---------------------------------------------------------------------------
// CASE 7 (positive): `?.` peels a nullable wrapper before member lookup,
// same as plain `.` on the peeled inner type.
fn ok_question_dot(f: Foo?) -> i32 { return f?.v }

// --- expected diagnostics, in source order ---------------------------------
// DIAG: '::' cannot follow a value; use '.' to access a member of 'f'
// DIAG: '.' cannot follow a type; use '::' to name a member of 'Foo'
// DIAG: '->' requires a pointer on its left; use '.' for a value
// DIAG: '.' cannot be applied to a pointer; use '->'
//
// The three correctly-paired positive cases must not error.
// DIAG-NOT: no member named 'v'
// DIAG-NOT: '->' requires a pointer{{.*}}p->v
// DIAG-NOT: cannot be applied to a pointer{{.*}}p->v

// --- bindings: the correctly-paired cases actually bind the field --------
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}member_chain_separators.k =====
// SEMA:      fn ok_arrow_on_pointer  @
// SEMA:        member  ->v  {{.*}} -> field v {{.*}}
// SEMA:      fn ok_dot_on_value  @
// SEMA:        member  .v  {{.*}} -> field v {{.*}}
// SEMA:      fn ok_question_dot  @
// SEMA:        member  ?.v  {{.*}} -> field v {{.*}}
