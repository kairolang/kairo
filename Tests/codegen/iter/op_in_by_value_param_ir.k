// A by-value container parameter that a loop only reads is passed as a
// `const T&`: the loop calls `op in (const self)`, which reads the
// parameter, so ParamPassInference infers it const and SC224W says to
// write `const`. A loop with a mutable pointer binder writes the
// parameter through `op in (self)`, and the parameter stays by value.

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
    return sum(v) + keys(m) + count(t) + bump(v) - 25
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=WARN --implicit-check-not="warning ["
// WARN: op_in_by_value_param_ir.k:7:8: warning [SC224W]: parameter 'v' is never mutated; declare it 'const'
// WARN: op_in_by_value_param_ir.k:16:9: warning [SC224W]: parameter 'm' is never mutated; declare it 'const'
// WARN: op_in_by_value_param_ir.k:25:10: warning [SC224W]: parameter 't' is never mutated; declare it 'const'
//
// RUN: %kairo %s --print-ir -w 2>/dev/null | %FileCheck %s --check-prefix=IR
// IR-DAG: sum(const{{ ?}}::builtin::containers::vector::Vector<signed int> & v)
// IR-DAG: keys(const{{ ?}}::builtin::containers::hash_map::HashMap<signed int, signed int> & m)
// IR-DAG: count(const{{ ?}}::builtin::containers::hash_set::HashSet<signed int> & t)
// IR-DAG: bump({{ ?}}::builtin::containers::vector::Vector<signed int> v)
//
// RUN: rm -rf %t.d
// RUN: %kairo %s -w -o %t.exe --cache-dir %t.d
// RUN: %t.exe
