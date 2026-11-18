// witness/diamond/main.k -- exit 16
// Interface (iface), conformer and its extension (metric), and two modules
// that both instantiate twice<Metric> (ua, ub): one object per module. Every
// TU holding the instance writes Metric's specialization, because each may
// compile the inline body (CODEGEN.md §7b.6); the constrained template's
// mangled name agrees between the home object and the others (§7b.7).
import ua
import ub
fn main() -> i32 {
    return ua::use_a() + ub::use_b()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | grep -cE 'template<> struct Scalable_witness< ?::([A-Za-z_]+::)*metric::Metric>' | %FileCheck %s --check-prefix=SPEC
// One specialization in each instantiating TU, in whichever order they print.
// The module path above `metric` follows the project root lit runs from.
// SPEC: {{^2$}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 16
// Both objects name the constrained instance, under one mangled name (the
// constraint is part of it), whichever of them homes the definition.
// RUN: find %t.d -name 'u[ab].o' | xargs nm | grep 'twice.*Scalable_c' | wc -l | %FileCheck %s --check-prefix=SYMS
// SYMS: {{^ *2$}}
// RUN: find %t.d -name 'u[ab].o' | xargs nm | grep 'twice.*Scalable_c' | awk '{print $NF}' | sort -u | wc -l | %FileCheck %s --check-prefix=ONE
// ONE: {{^ *1$}}
