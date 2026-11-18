// A list literal takes its target from the expected type: `[T; N]`, `[T;]` or
// `[T]`. With none it is `[T; N]`. In argument position it is ranked by shape
// and typed after selection, so the three targets are one overload set.

fn takes_arr(const xs: [i32; 3]) -> i32 { return 0 }
fn takes_slice(const xs: [i32;]) -> i32 { return 0 }
fn takes_vec(const xs: [i32]) -> i32 { return 0 }
fn takes_wide(const xs: [i64;]) -> i32 { return 0 }

fn pick(const xs: [i32; 3]) -> i32 { return 0 }
fn pick(const xs: [i32;]) -> i64 { return 0 }
fn pick(const xs: [i32]) -> f64 { return 0.0 }

fn <T> first(const xs: [T;]) -> i32 { return 0 }

fn typing(x: i32) {
    var arr = [1, 2, 3];
    var view: [i32;] = [1, 2, 3];
    var own:  [i32]  = [1, 2, 3];
    var none: [i32]  = [];
    var a = takes_arr([1, 2, 3]);
    var s = takes_slice([1, 2, 3]);
    var v = takes_vec([1, 2, 3]);
    var w = takes_wide([x, 2]);
    var g = first([1, 2]);
    var exact = pick([1, 2, 3]);
}

fn ambiguous() {
    var t = pick([1, 2]);
}

fn count_mismatch() {
    var bad: [i32; 2] = [1, 2, 3];
}

fn returned() -> [i32;] {
    return [1, 2, 3]
}

fn assigned() {
    var s: [i32;] = [1];
    s = [2, 3];
}

struct Holder {
    var xs: [i32;] = [1, 2]
}

struct View {
    var xs: [i32;]
}

fn stored() {
    var v = View{ xs: [1, 2] };
}

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: call to 'pick' is ambiguous
// DIAG: array literal has 3 element(s), but '[i32; 2]' needs 2
// DIAG: a list literal returned from a function is a view of a temporary array
// DIAG: a list literal assigned to a slice is a view of a temporary array
// DIAG: a list literal used as a field default is a view of a temporary array
// DIAG: a list literal stored in a field is a view of a temporary array

// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}list_literals.k =====
// SEMA: arr : [i32; 3]
// SEMA: exact : i32
