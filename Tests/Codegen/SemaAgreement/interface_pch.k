// A body the interface PCH holds (a generic's, an inline function's) is
// parsed by the PCH's build and by no TU, so the Sema agreement pass walks
// it there. What it finds is reported at the call, stored with the object
// of the TU whose file holds the call, and said again from the cache.
//
// Inputs/pch: util.k has `fn <T> twice` calling `chosen`; the hidden
// --test-sema-agreement-swap=chosen:other tells the pass that Kairo bound
// that call to `other`.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
//
// Cold: the PCH's walk joins the call and finds it.
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/Inputs/pch %t.d/s
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a -v -fsema-agreement --sema-agreement-summary --interface-pch=on --cache-dir %t.d/c --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=COLD
// COLD: sema agreement: 1 calls recorded, 1 joined, {{.*}} 1 disagreed in the interface PCH
// COLD: kairo: sema agreement: 1 finding(s) in 1 of {{[0-9]+}} file(s) (callee 1)
// COLD: util.k:7:40: warning [I012W]: internal: clang resolved this call to 'util::chosen(int)', but Kairo's Sema chose 'other'; this is a compiler bug
// COLD-NEXT: util.k:5:8: note [I900N]: Kairo's Sema chose this declaration
// COLD-NEXT: util.k:4:8: note [I900N]: clang resolved the call to this declaration
// COLD-NOT: I012W
//
// Warm: no PCH is built, and the finding comes from util's object.
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a -v -fsema-agreement --sema-agreement-summary --interface-pch=on --cache-dir %t.d/c --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=WARM
// WARM-NOT: in the interface PCH
// WARM: incremental: reused util
// WARM-NOT: in the interface PCH
// WARM: kairo: sema agreement: 1 finding(s) in 1 of {{[0-9]+}} file(s) (callee 1)
// WARM: util.k:7:40: warning [I012W]
// WARM-NOT: I012W
//
// Another TU changes: the PCH is built and walked again while util's
// object is reused. The finding is said once, not twice.
// RUN: sed -e 's/plain(0)/plain(0) + 0/' %t.d/s/main.k > %t.d/m && mv %t.d/m %t.d/s/main.k
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a -v -fsema-agreement --sema-agreement-summary --interface-pch=on --cache-dir %t.d/c --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=EDIT
// EDIT: incremental: reused util
// EDIT: incremental: compiling main
// EDIT: 1 disagreed in the interface PCH
// EDIT: kairo: sema agreement: 1 finding(s) in 1 of {{[0-9]+}} file(s) (callee 1)
// EDIT: util.k:7:40: warning [I012W]
// EDIT-NOT: I012W
//
// Off: the PCH's parse has no walk either.
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a -v -fno-sema-agreement --interface-pch=on --cache-dir %t.d/c --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=OFF
// OFF-NOT: sema agreement:
// OFF-NOT: I012W
// OFF: compilation:
