// `&null` stored in a safe pointer `*T` is an error in every position a
// value lands in one (pointers.mdx: `*T` is never null). The label is the
// literal; the note points at the slot's declared type and says why; the
// fix-it makes that type `*T?`. Where no written type is at hand (a call
// through a `fn` value) the note stands alone, without a fix-it. What may
// hold `&null` -- `*T?`, `unsafe *T`, a comparison -- is in
// Codegen/nullable/null_pointer_targets.k.

class Node {
    pub var v: i32 = 0
    pub var next: *Node = &null                     // field default
    fn reset(self) { self.next = &null }            // a field through `self`
}

struct Pair {
    var a: *i32
    var b: i32
}

fn take(p: *i32) -> i32 { return 1 }
fn give() -> *i32 { return &null }                 // return
fn defaulted(p: *i32 = &null) -> i32 { return 2 }  // default argument
fn <T> generic_take(p: *T) -> i32 { return 3 }
fn <T> generic_local() -> i32 {
    var p: *T = &null                               // generic `*T`
    return 4
}

fn main() -> i32 {
    var x: i32 = 1
    var p: *i32 = &null                             // var init
    var q: *i32 = &x
    q = &null                                       // assignment
    take(&null)                                     // argument
    generic_take<i32>(&null)                        // generic argument
    var s = Pair { a: &null, b: 2 }                 // struct literal
    var c = true
    var t: *i32 = if c => &x else => &null         // `if` expression arm
    var k: *const i32 = &null                       // pointer to const
    var f: fn(*i32) -> i32 = take
    f(&null)                                        // a fn value's parameter
    var maybe: *i32? = &x
    var g: *i32 = maybe ?? &null                    // the fallback of `??`
    return x
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:11:27: error [SC001E]: '&null' cannot be stored in '*Node': a safe pointer is never null
// DIAG-NEXT: fix-it:"{{.*}}":{11:24-11:24}:"?"
// DIAG-NEXT: {{.*}}:11:19: note [I900N]: 'next' is declared '*Node' here; a pointer that may be absent is '*Node?', and a raw pointer that may hold '&null' is 'unsafe *Node'
// DIAG: {{.*}}:12:34: error [SC001E]: '&null' cannot be stored in '*Node': a safe pointer is never null
// DIAG-NEXT: fix-it:"{{.*}}":{11:24-11:24}:"?"
// DIAG-NEXT: {{.*}}:11:19: note [I900N]: 'next' is declared '*Node' here; a pointer that may be absent is '*Node?', and a raw pointer that may hold '&null' is 'unsafe *Node'
// DIAG: {{.*}}:21:28: error [SC001E]: '&null' cannot be stored in '*i32': a safe pointer is never null
// DIAG-NEXT: fix-it:"{{.*}}":{21:18-21:18}:"?"
// DIAG-NEXT: {{.*}}:21:14: note [I900N]: 'give' is declared to return '*i32' here; a pointer that may be absent is '*i32?', and a raw pointer that may hold '&null' is 'unsafe *i32'
// DIAG: {{.*}}:22:24: error [SC001E]: '&null' cannot be stored in '*i32': a safe pointer is never null
// DIAG-NEXT: fix-it:"{{.*}}":{22:21-22:21}:"?"
// DIAG-NEXT: {{.*}}:22:17: note [I900N]: 'p' is declared '*i32' here; a pointer that may be absent is '*i32?', and a raw pointer that may hold '&null' is 'unsafe *i32'
// DIAG: {{.*}}:25:17: error [SC001E]: '&null' cannot be stored in '*T': a safe pointer is never null
// DIAG-NEXT: fix-it:"{{.*}}":{25:14-25:14}:"?"
// DIAG-NEXT: {{.*}}:25:12: note [I900N]: 'p' is declared '*T' here; a pointer that may be absent is '*T?', and a raw pointer that may hold '&null' is 'unsafe *T'
// DIAG: {{.*}}:31:19: error [SC001E]: '&null' cannot be stored in '*i32': a safe pointer is never null
// DIAG-NEXT: fix-it:"{{.*}}":{31:16-31:16}:"?"
// DIAG-NEXT: {{.*}}:31:12: note [I900N]: 'p' is declared '*i32' here; a pointer that may be absent is '*i32?', and a raw pointer that may hold '&null' is 'unsafe *i32'
// DIAG: {{.*}}:33:9: error [SC001E]: '&null' cannot be stored in '*i32': a safe pointer is never null
// DIAG-NEXT: fix-it:"{{.*}}":{32:16-32:16}:"?"
// DIAG-NEXT: {{.*}}:32:12: note [I900N]: 'q' is declared '*i32' here; a pointer that may be absent is '*i32?', and a raw pointer that may hold '&null' is 'unsafe *i32'
// DIAG: {{.*}}:34:10: error [SC001E]: '&null' cannot be stored in '*i32': a safe pointer is never null
// DIAG-NEXT: fix-it:"{{.*}}":{20:16-20:16}:"?"
// DIAG-NEXT: {{.*}}:20:12: note [I900N]: 'p' is declared '*i32' here; a pointer that may be absent is '*i32?', and a raw pointer that may hold '&null' is 'unsafe *i32'
// DIAG: {{.*}}:35:23: error [SC001E]: '&null' cannot be stored in '*i32': a safe pointer is never null
// DIAG-NEXT: fix-it:"{{.*}}":{23:26-23:26}:"?"
// DIAG-NEXT: {{.*}}:23:24: note [I900N]: 'p' is declared '*i32' here; a pointer that may be absent is '*i32?', and a raw pointer that may hold '&null' is 'unsafe *i32'
// DIAG: {{.*}}:36:23: error [SC001E]: '&null' cannot be stored in '*i32': a safe pointer is never null
// DIAG-NEXT: fix-it:"{{.*}}":{16:16-16:16}:"?"
// DIAG-NEXT: {{.*}}:16:12: note [I900N]: 'a' is declared '*i32' here; a pointer that may be absent is '*i32?', and a raw pointer that may hold '&null' is 'unsafe *i32'
// DIAG: {{.*}}:38:38: error [SC001E]: '&null' cannot be stored in '*i32': a safe pointer is never null
// DIAG-NEXT: fix-it:"{{.*}}":{38:16-38:16}:"?"
// DIAG-NEXT: {{.*}}:38:12: note [I900N]: 't' is declared '*i32' here; a pointer that may be absent is '*i32?', and a raw pointer that may hold '&null' is 'unsafe *i32'
// DIAG: {{.*}}:39:25: error [SC001E]: '&null' cannot be stored in '*const i32': a safe pointer is never null
// DIAG-NEXT: fix-it:"{{.*}}":{39:22-39:22}:"?"
// DIAG-NEXT: {{.*}}:39:12: note [I900N]: 'k' is declared '*const i32' here; a pointer that may be absent is '*const i32?', and a raw pointer that may hold '&null' is 'unsafe *const i32'
// DIAG: {{.*}}:41:7: error [SC001E]: '&null' cannot be stored in '*i32': a safe pointer is never null
// DIAG: {{.*}}:43:28: error [SC001E]: '&null' cannot be stored in '*i32': a safe pointer is never null
// DIAG-NEXT: fix-it:"{{.*}}":{43:16-43:16}:"?"
// DIAG-NEXT: {{.*}}:43:12: note [I900N]: 'g' is declared '*i32' here; a pointer that may be absent is '*i32?', and a raw pointer that may hold '&null' is 'unsafe *i32'
// END-GENERATED-CHECKS(DIAG)
