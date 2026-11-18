// A header leaves out a non-`pub` declaration by its root rule, but a
// visible body in ANOTHER file's header may name one: lib/scope.hh's
// template bodies call lib/counter.k's `prot inline` push/pop, and so did
// builtin/base/alloc.hh's AllocatorScope call alloc_raw's scope_push /
// scope_pop. The including header saw no declaration and did not compile on
// its own. The home header (counter.hh, alloc_raw.hh) declares such a
// decl, as it declares a hidden helper its own inline body names, with the
// linkage the module's object gives it; no other header changes.
import lib::scope::Scope

fn main() -> i32 {
    {
        var s = Scope<i32>()
    }
    return 0
}

// --- lit wiring ---
// REQUIRES: kcc
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S && %kairo main.k --type-check-only --emit-headers %t.d/h
// RUN: %FileCheck %s --check-prefix=HOME < %t.d/h/lib/counter.hh
// HOME: push()
// HOME: pop(
// RUN: for h in lib/scope.hh lib/counter.hh builtin/base/alloc.hh builtin/alloc_raw.hh; do \
// RUN:   printf '#include "%%s"\n' $h > %t.d/one.cc; \
// RUN:   %kcc -fsyntax-only -I %t.d/h %t.d/one.cc || echo "FAILED $h"; done > %t.d/one.out
// RUN: %FileCheck %s --check-prefix=ALONE --allow-empty < %t.d/one.out
// ALONE-NOT: FAILED
// RUN: cd %t.d/h && find . -name '*.hh' | sort | sed 's/.*/#include "&"/' > %t.d/all.cc
// RUN: %kcc -fsyntax-only -I %t.d/h %t.d/all.cc
//
// The program itself still builds and runs.
// RUN: cd %S && %kairo main.k -o %t.exe --cache-dir %t.d/c
// RUN: %t.exe
