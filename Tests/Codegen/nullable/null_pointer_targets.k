// Where `&null` may go (pointers.mdx): a nullable pointer `*T?` / `(*T)?`
// takes it as that nullable's null, a raw `unsafe *T` holds the null
// address, a C function's pointer parameter is raw, and a comparison with a
// safe `*T` stores nothing. Each in the positions the error covers
// (Sema/Check/null_into_safe_pointer.k): an initializer, a field default,
// an assignment, an argument, a default argument, a return, a struct
// literal, an `if` arm, a generic `*T?`. Compiled and run, so each one also
// lowers.

ffi "c" import "stdlib.h"

class Node {
    pub var v: i32 = 0
    pub var next: *Node? = &null
    pub var raw: unsafe *Node = &null
}

struct Link {
    var to: *i32?
    var n: i32
}

fn take(p: *i32?) -> i32 { if p == null { return 1 } return 2 }
fn give() -> *i32? { return &null }
fn defaulted(p: unsafe *i32 = &null) -> i32 { if p == &null { return 3 } return 0 }
fn <T> generic_take(p: *T?) -> i32 { if p == null { return 4 } return 0 }
fn <T> generic_local() -> i32 {
    var p: *T? = &null
    var r: unsafe *T = &null
    if (p == null) && (r == &null) { return 5 }
    return 0
}

fn main() -> i32 {
    var x: i32 = 1
    var n = 0
    var p: *i32? = &null
    var pp: (*i32)? = &null
    var r: unsafe *i32 = &null
    var k: *const i32? = &null
    if (p == null) && (pp == null) && (r == &null) && (k == null) { n += 1 }   // 1
    var q: *i32 = &x
    if q == &null { n += 100 }
    if &null != q { n += 1 }                                                    // 2
    p = &x
    p = &null
    r = &null
    if give() == null { n += 1 }                                                // 3
    n += take(&null)                                                            // 4
    n += defaulted()                                                            // 7
    n += generic_take<i32>(&null)                                               // 11
    n += generic_local<i32>()                                                   // 16
    unsafe { free(&null) }
    var c = true
    var t: *i32? = if c => &null else => &x
    if t == null { n += 1 }                                                     // 17
    var l = Link { to: &null, n: 2 }
    if l.to == null { n += l.n }                                                // 19
    var node = Node()
    if (node.next == null) && (node.raw == &null) { n += 1 }                    // 20
    return n
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 20
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
