// A slice is copied into a vector with `[T]::from_slice(s)`, not with a
// cast: `s as [T]` is SC027E, and the fix-it rewrites the whole cast into
// that call, keeping the operand as written. A const slice, an expression
// operand and a nullable target are refused the same way; a vector of
// other elements is refused with no fix-it, since `from_slice` copies the
// elements as they are. The call itself, and a vector cast to its own
// type, are accepted.

fn takes_vec(const xs: [i32]) -> usize { return xs.size() }

fn written(const s: [i32;]) -> usize { return takes_vec(s as [i32]) }
fn const_elems(const s: [const i32;]) -> usize { return takes_vec(s as [i32]) }
fn sub_slice(const v: [i32]) -> usize { return takes_vec(v[0..1] as [i32]) }
fn called(const s: [i32;]) -> usize { return takes_vec([i32]::from_slice(s)) }
fn same(const v: [i32]) -> usize { return takes_vec(v as [i32]) }
fn nullable(const s: [i32;]) -> bool { var v = s as [i32]?; return v == null }
fn widened(const s: [i32;]) -> usize { var v = s as [i64]; return v.size() }

fn main() -> i32 {
    var v: [i32] = [1, 2, 3]
    var s: [i32;] = v
    return called(s) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -w 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG: :11:57: error [SC027E]: a slice does not cast to a vector; copy it with '[i32]::from_slice'
// DIAG-NEXT: fix-it:"{{.*}}":{11:57-11:67}:"[i32]::from_slice(s)"
// DIAG: :12:67: error [SC027E]: a slice does not cast to a vector; copy it with '[i32]::from_slice'
// DIAG-NEXT: fix-it:"{{.*}}":{12:67-12:77}:"[i32]::from_slice(s)"
// DIAG: :13:58: error [SC027E]: a slice does not cast to a vector; copy it with '[i32]::from_slice'
// DIAG-NEXT: fix-it:"{{.*}}":{13:58-13:74}:"[i32]::from_slice(v[0..1])"
// DIAG: :16:48: error [SC027E]: a slice does not cast to a vector; copy it with '[i32]::from_slice'
// DIAG-NEXT: fix-it:"{{.*}}":{16:48-16:59}:"[i32]::from_slice(s)"
// DIAG: :17:48: error [SC027E]: a slice does not cast to a vector, and 'const [i32;]' does not hold the elements of '[i64]'
// DIAG-NOT: fix-it
