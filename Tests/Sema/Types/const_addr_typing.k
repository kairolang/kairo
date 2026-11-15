// `const &x` is the address of `x` as a pointer to const: `*const T` for
// a mutable `x` and a const one alike, and `unsafe const &x` is an
// `unsafe *const T`. Nothing writes through it, it is never the `&` marker
// of an `@inout` argument, and it takes no temporary's address. The other
// order, `const unsafe &x`, is S096E (its own file, as a parse error stops
// the run).

fn read(p: *const i32) -> i32 {
    return *p
}

fn bump(@inout x: i32) {
    x += 1
}

fn make() -> i32 {
    return 1
}

fn main() -> i32 {
    var a = 1
    const k = 2
    var n1: i32 = const &a
    var n2: i32 = const &k
    var n3: i32 = unsafe const &a
    var p = const &a
    var q: *i32 = const &a
    p[0] = 3
    bump(const &a)
    var t = const &make()
    var f: fn(@inout i32) -> void = bump
    f(const &a)
    return read(const &a)
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: const_addr_typing.k:23:19: error [SC028E]: cannot convert '*const i32' to 'i32'
// CHECK: const_addr_typing.k:24:19: error [SC028E]: cannot convert '*const i32' to 'i32'
// CHECK: const_addr_typing.k:25:19: error [SC028E]: cannot convert 'unsafe *const i32' to 'i32'
// CHECK: const_addr_typing.k:27:19: error [SC028E]: cannot convert '*const i32' to '*i32'
// CHECK: const_addr_typing.k:28:5: error [SC071E]:
// CHECK: const_addr_typing.k:29:5: error [SC063E]: no matching overload for call to 'bump'
// CHECK: note [I900N]: candidate not viable: parameter 'x' is '@inout' and writes its argument; 'const &' makes a pointer to const, not the '&' marker
// CHECK: const_addr_typing.k:30:13: error [SC069E]: cannot take the address of a temporary
// CHECK: const_addr_typing.k:32:7: error [SC097E]: 'const &' cannot mark an argument to '@inout' parameter 1 of 'fn (@inout i32)': the parameter writes its argument, and 'const &' makes a pointer to const
// CHECK-NEXT: fix-it:"{{.*}}const_addr_typing.k":{32:7-32:13}:""
