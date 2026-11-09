// mono_reached/swapped.k -- exit 16
// main.k with its two imports swapped. ub is now sema'd first, but the home
// does not follow the import order: it is the least module path among the
// non-dominated users (EmitPlan::assign_homes, Generics.md D3), so ua homes
// `outer<i32>` and everything its body reaches in both orders, and it is
// still ONE TU, the same for the named instance and the reached ones.
import ub
import ua
fn main() -> i32 {
    return ua::use_a() + ub::use_b()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } > %t.ir
// RUN: awk '/CODEGEN C\+\+: .*mono_reached\/ub\.k/{p=1;next} /CODEGEN C\+\+:/{p=0} p' %t.ir | grep -cE '^extern template[ (s].*gen::(Wrap|outer|inner|leaf)<' | %FileCheck %s --check-prefix=UB
// UB: {{^5$}}
// RUN: awk '/CODEGEN C\+\+: .*mono_reached\/ua\.k/{p=1;next} /CODEGEN C\+\+:/{p=0} p' %t.ir | grep -cE '^template[ (s].*gen::(Wrap|outer|inner|leaf)<' | %FileCheck %s --check-prefix=UA
// UA: {{^5$}}
// RUN: grep -cE '^template[ (s].*gen::(Wrap|outer|inner|leaf)<' %t.ir | %FileCheck %s --check-prefix=DEFS
// DEFS: {{^5$}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 16
