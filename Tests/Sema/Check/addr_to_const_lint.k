// SC310W: a plain `&x` (a `*T`) converted where a pointer to const is
// expected, at an argument, an initializer, an assignment, a return, a
// yield and a tuple element. The fix-it writes `const &x`, and the fixed
// file compiles with no SC310W. Not warned: `const &x`, `unsafe &x`, the
// `&x` marker of an `@inout` argument, a `*T` variable passed where a
// `*const T` is expected, `&x` into a `*T`, an `&` a macro body wrote,
// and an address that is already a `*const T`.

macro addr!(v) {
    &v
}

fn read(p: *const i32) -> i32 {
    return *p
}

fn bump(@inout x: i32) {
    x += 1
}

fn give(p: *i32) -> *const i32 {
    return &*p
}

fn gen(p: *i32) -> yield *const i32 {
    yield &*p
}

fn pair(t: (*const i32, *i32)) -> i32 {
    return *t.0 + *t.1
}

fn main() -> i32 {
    var a = 1
    var b = 2
    const k = 3
    var s = read(&a)
    var q: *const i32 = &a
    q = &b
    s += pair((&a, &b))
    s += *give(&a)
    for x in gen(&b) {
        s += *x
    }

    s += read(const &a)
    var r: unsafe *const i32 = unsafe &a
    bump(&a)
    var m: *i32 = &b
    s += read(m)
    s += read(addr!(a))
    s += read(&k)
    var w: *i32 = &a
    return s + *q - 17 + *w - 2
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="warning [SC310W]" --implicit-check-not="error ["
// RUN: rm -rf %t && mkdir -p %t && cp %s %t/al.k
// RUN: { %kairo %t/al.k --type-check-only 2>&1 || true; } > %t/diag.txt
// RUN: python3 %S/../../../Scripts/apply_fixits.py --code SC310W --from %t/diag.txt 2>&1 | %FileCheck %s --check-prefix=APPLIED
// RUN: { %kairo %t/al.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=AFTER --allow-empty --implicit-check-not="warning [SC310W]"
// RUN: %kairo %t/al.k -w -o %t/al.exe --cache-dir %t/c
// RUN: %t/al.exe
//
// CHECK: addr_to_const_lint.k:22:12: warning [SC310W]: '&' makes a '*i32' where a '*const i32' is expected; write 'const &' to take a pointer to const
// CHECK-NEXT: fix-it:"{{.*}}addr_to_const_lint.k":{22:12-22:12}:"const "
// CHECK: addr_to_const_lint.k:26:11: warning [SC310W]
// CHECK: addr_to_const_lint.k:37:18: warning [SC310W]
// CHECK-NEXT: fix-it:"{{.*}}addr_to_const_lint.k":{37:18-37:18}:"const "
// CHECK: addr_to_const_lint.k:38:25: warning [SC310W]
// CHECK: addr_to_const_lint.k:39:9: warning [SC310W]
// CHECK: addr_to_const_lint.k:40:16: warning [SC310W]
//
// APPLIED: changed 1 file(s)
// AFTER-NOT: SC310W
