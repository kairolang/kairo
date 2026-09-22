// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// The container lang items. `[T]`, `{T}`, `{K: V}` and `[T;]` resolve to the
// records declared in Lib/builtin -- Vector, HashSet, HashMap and Slice --
// rather than to structural canonical kinds. `[T; N]` is the exception and
// stays a structural array.
//
// The dump quotes the SUGAR (`[i32]`, not `Vector<i32>`), which is what makes
// these rows readable; the record identity is what `extend` and overload
// resolution key on.

fn containers(v: [i32], s: {i32}, m: {string: i32}, sl: [i32;], const a: [i32; 3]) { }

// An extension on the sugar reaches the Vector primary: after the migration
// `extend <T> [T]` targets record(Vector, [T]) like any generic extension on
// a record, so the shape index MemberLookup used to need is gone.
extend <T> [T] {
    fn first(const self) -> T
}

fn uses_extension(v: [i32]) {
    var f = v.first();
}

// A `[T; N]` target with exactly N elements takes the array type outright.
fn array_literal() {
    var a: [i32; 3] = [1, 2, 3];
}

// Anything else is a slice, which converts to a vector at Converted.
fn slice_then_vector() {
    var x: [i32] = [1, 2];
}

// DIAG-NOT: error

// The prelude dumps the builtin TUs ahead of this one, each with sections of
// the same names: anchor on this file's header first.
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}containers.k =====
// SEMA: -- lang items (well_known) --
