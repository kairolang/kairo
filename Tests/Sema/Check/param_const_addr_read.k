// `const &v` makes a `*const T` nothing writes through, so taking it
// reads the parameter: a by-value parameter whose body only takes
// `const &v` is never mutated (SC224W) and passed as `const T&`. A plain
// `&v` (a `*T`) keeps the copy.

fn reads(v: [i32]) -> usize {
    const *p = const &v
    return p->size()
}

fn writes(v: [i32]) -> usize {
    var *p = &v
    p->push(2)
    return p->size()
}

fn main() -> i32 {
    var v: [i32] = [1]
    return (reads(v) + writes(v)) as i32 - 3
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="warning [" --implicit-check-not="error ["
// CHECK: param_const_addr_read.k:6:10: warning [SC224W]: parameter 'v' is never mutated; declare it 'const'
// CHECK-NEXT: fix-it:{{.*}}
//
// RUN: %kairo %s --print-ir -w 2>/dev/null | %FileCheck %s --check-prefix=IR
// IR-DAG: reads(const{{ ?}}::builtin::containers::vector::Vector<signed int> & v)
// IR-DAG: writes({{ ?}}::builtin::containers::vector::Vector<signed int> v)
//
// RUN: rm -rf %t.d
// RUN: %kairo %s -w -o %t.exe --cache-dir %t.d
// RUN: %t.exe
