// mono_reached/main.k -- exit 16
// An instance reached only through a generic body gets exactly one explicit
// instantiation, in its home, like a named one (MONO.md G2). ua and ub both
// call `gen::outer(i32)`. `outer<i32>`'s body reaches `inner<Wrap<i32>>` and
// `Wrap<i32>`, and `inner`'s reaches `leaf<Wrap<Wrap<i32>>>` and
// `Wrap<Wrap<i32>>`: none of them is named in any file. ConformanceChecking
// records each as reached by the instance whose body names it
// (InstanceEntry::reached), minted in ua, which names `outer<i32>` first;
// every plan holding `outer<i32>` holds what it reaches, so ua writes
// `template ...;` for all five and ub `extern template` for all five.
// Before, only `outer<i32>` had a tier-3 line and the rest were weak
// implicit instantiations in whichever object compiled them.
import ua
import ub
fn main() -> i32 {
    return ua::use_a() + ub::use_b()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } > %t.ir
// RUN: awk '/CODEGEN C\+\+: .*mono_reached\/ua\.k/{p=1;next} /CODEGEN C\+\+:/{p=0} p' %t.ir | grep -E '^(extern )?template[ (s]' | %FileCheck %s --check-prefix=UA
// UA-DAG: {{^}}template struct{{ ?}}::{{([A-Za-z_]+::)*}}gen::Wrap<signed int>;
// UA-DAG: {{^}}template struct{{ ?}}::{{([A-Za-z_]+::)*}}gen::Wrap<{{ ?}}::{{([A-Za-z_]+::)*}}gen::Wrap<signed int>>;
// UA-DAG: {{^}}template signed int({{ ?}}::{{([A-Za-z_]+::)*}}gen::outer<signed int>)
// UA-DAG: {{^}}template signed int({{ ?}}::{{([A-Za-z_]+::)*}}gen::inner<{{ ?}}::{{([A-Za-z_]+::)*}}gen::Wrap<signed int>>)
// UA-DAG: {{^}}template signed int({{ ?}}::{{([A-Za-z_]+::)*}}gen::leaf<{{ ?}}::{{([A-Za-z_]+::)*}}gen::Wrap<{{ ?}}::{{([A-Za-z_]+::)*}}gen::Wrap<signed int>>>)
// RUN: awk '/CODEGEN C\+\+: .*mono_reached\/ub\.k/{p=1;next} /CODEGEN C\+\+:/{p=0} p' %t.ir | grep -E '^(extern )?template[ (s]' | %FileCheck %s --check-prefix=UB
// UB-DAG: {{^}}extern template struct{{ ?}}::{{([A-Za-z_]+::)*}}gen::Wrap<signed int>;
// UB-DAG: {{^}}extern template struct{{ ?}}::{{([A-Za-z_]+::)*}}gen::Wrap<{{ ?}}::{{([A-Za-z_]+::)*}}gen::Wrap<signed int>>;
// UB-DAG: {{^}}extern template signed int({{ ?}}::{{([A-Za-z_]+::)*}}gen::outer<signed int>)
// UB-DAG: {{^}}extern template signed int({{ ?}}::{{([A-Za-z_]+::)*}}gen::inner<{{ ?}}::{{([A-Za-z_]+::)*}}gen::Wrap<signed int>>)
// UB-DAG: {{^}}extern template signed int({{ ?}}::{{([A-Za-z_]+::)*}}gen::leaf<{{ ?}}::{{([A-Za-z_]+::)*}}gen::Wrap<{{ ?}}::{{([A-Za-z_]+::)*}}gen::Wrap<signed int>>>)

// Exactly one definition build-wide for each: five `template` lines naming
// gen's entities, all in ua, and five `extern template`, all in ub.
// RUN: grep -cE '^template[ (s].*gen::(Wrap|outer|inner|leaf)<' %t.ir | %FileCheck %s --check-prefix=DEFS
// DEFS: {{^5$}}
// RUN: grep -cE '^extern template[ (s].*gen::(Wrap|outer|inner|leaf)<' %t.ir | %FileCheck %s --check-prefix=DECLS
// DECLS: {{^5$}}

// Deterministic: the worklist keeps mint order, so a second run writes the
// same bytes.
// RUN: { %kairo %s --print-ir 2>&1 || true; } > %t.ir2
// RUN: diff %t.ir %t.ir2

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 16
