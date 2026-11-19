// A by-value container parameter is a move-only value passed by value
// (moved in), whether a loop only reads it (`op in (const self)`) or writes
// it through a mutable pointer binder (`op in (self)`): ParamPassInference
// and SC224W apply to copyable records only, so no `const T&` is inferred
// and nothing is warned.

fn sum(v: [i32]) -> i32 {
    var s = 0
    for x in v {
        s += x
    }

    return s
}

fn keys(m: {i32: i32}) -> i32 {
    var s = 0
    for (k, v) in m {
        s += k * v
    }

    return s
}

fn count(t: {i32}) -> i32 {
    var s = 0
    for x in t {
        s += x
    }

    return s
}

fn bump(v: [i32]) -> i32 {
    var s = 0
    for *x in v {
        *x += 1
        s += *x
    }

    return s
}

fn main() -> i32 {
    var v: [i32] = [1, 2, 3]
    var m: {i32: i32} = {2: 3}
    var t: {i32} = {4}
    // 6 + 6 + 4 + 9
    return sum(v.copy()) + keys(m) + count(t) + bump(v) - 25
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=WARN --allow-empty --implicit-check-not="warning ["
// WARN-NOT: warning
//
//
//
// RUN: %kairo %s --print-ir -w 2>/dev/null | %FileCheck %s --check-prefix=IR
// IR-DAG: sum({{ ?}}::builtin::containers::vector::Vector<signed int> v)
// IR-DAG: keys({{ ?}}::builtin::containers::hash_map::HashMap<signed int, signed int> m)
// IR-DAG: count({{ ?}}::builtin::containers::hash_set::HashSet<signed int> t)
// IR-DAG: bump({{ ?}}::builtin::containers::vector::Vector<signed int> v)
//
// RUN: rm -rf %t.d
// RUN: %kairo %s -w -o %t.exe --cache-dir %t.d
// RUN: %t.exe
