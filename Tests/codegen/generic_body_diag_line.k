// A clang error inside a generic body reports the Kairo line it is on,
// however much C++ the functions above it emitted. Each emitted token
// borrows a byte of the Kairo source as its location, one per token; the
// signatures and namespace wrappers of a1..a3, anchored on short names,
// run on through the bytes after them, so the `.` below must not find its
// own byte taken by a token from the signature. Clang's "member reference base
// type" error, stays on the `.` and does not land on the closing brace below it.
// The token anchored on a byte takes it back from one that walked there.

fn a1(v: i32) -> i32 { return v * 2 }
fn a2(v: i32) -> i32 { return v * 3 }
// a comment
fn a3(v: i32) -> i32 { return v * 4 }

fn <T: type> pick(x: T) -> i32 {
    var y: i32 = 1
    return x.missing(y)
}

fn main() -> i32 { return pick(3) + a1(1) + a2(1) + a3(1) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -fduck-generics --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -fduck-generics -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: generic_body_diag_line.k:17:13: error [CL001E]: member reference base type 'int' is not a structure or union
