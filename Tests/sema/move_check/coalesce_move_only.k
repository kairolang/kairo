// XFAIL: *
// Waiting on: move checking a `??` operand whose payload cannot be copied
// as a transfer of that operand. Today the C++ copy reaches clang (an error
// there, not here).
// `x ?? y` takes the value out of `x` when it is not null. With a payload
// that cannot be copied (string, a container), a local or by-value
// parameter read for the last time moves into the result; read again, it
// is SC182E rather than a copy C++ cannot make.

fn last_use(r: string?) -> usize {
    var x = r ?? ""
    return x.size()
}

fn local_last_use() -> usize {
    var r: string? = "abc"
    var x = r ?? "zz"
    return x.size()
}

fn none() -> usize {
    var r: string? = null
    return (r ?? "four").size()
}

fn main() -> i32 {
    return (last_use("ab") + local_last_use() + none()) as i32   // 2 + 3 + 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9
// RUN: { %kairo %S/inputs/coalesce_move_only_reused.k --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: coalesce_move_only_reused.k:2:13: error [SC182E]: {{.*}}'??' takes the value out of 'r' when it is not null, and that value cannot be copied
