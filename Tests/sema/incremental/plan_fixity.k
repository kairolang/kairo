// Incremental Sema: a marked `op l++` / `op r++` defined out of line is
// listed under its operator's lookup key, the key a scope's symbol table
// holds it under and a dependency row names it by. The `l` / `r` marker is
// not part of the key (`op l++` and `op r++` share one cell and are told
// apart by fixity), so the declaration in the class, its out-of-line
// definition and the scope's name set all spell the same `op#<kinds>`.
//
// inputs/fixity: lib.k declares both operators in class C and defines them
// below it; mid.k names them in the body of a generic, `bump`; main.k
// instantiates `bump`, so it reads that body.
//
// The interface dump - both entries of each operator carry the name the
// scope lists.
//
// The plan - a body-only edit of the out-of-line `op r++` is a changed body
// under that name. mid.k names it (a name row from the lookup of `++`), so
// main.k, which reads mid.k's generic body, is re-checked by R6. Under any
// other key the definition's body is one no row names, and the plan holds
// lib.k alone.
//
// The replay - the live check re-checks the same edits in place and agrees
// with a fresh run at each step (it reads the interface by DeclId, not by
// name).

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/inputs/fixity %t.d/s
// RUN: cd %t.d && %kairo -I s s/main.k --type-check-only --dump-interface=%t.d/i.json
// RUN: %FileCheck %s --check-prefix=IFACE --input-file=%t.d/i.json
//
// IFACE: {"id": "lib#class:C/fn:op l++(self)", "scope": "lib#class:C", "name": "op#[[K:[0-9]+]]", "kind": "fn"
// IFACE-NEXT: {"id": "lib#class:C/fn:op l++(self)", "scope": "lib#class:C", "name": "op#[[K]]", "kind": "fn"
// IFACE-NEXT: {"id": "lib#class:C/fn:op r++(self)", "scope": "lib#class:C", "name": "op#[[K]]", "kind": "fn"
// IFACE-NEXT: {"id": "lib#class:C/fn:op r++(self)", "scope": "lib#class:C", "name": "op#[[K]]", "kind": "fn"
// IFACE: {"scope": "lib#class:C", "ext": "", "names": ["<ctor>", "op#[[K]]", "v"]}
//
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=NONE --input-file=%t.d/o
// RUN: sed -e 's/self.v += 1/self.v += 2/' %t.d/s/lib.k > %t.d/u && mv %t.d/u %t.d/s/lib.k
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only --cache-dir c --incremental-sema --incr-verify --print-incr-plan > o 2> e || true; }
// RUN: %FileCheck %s --check-prefix=PLAN --input-file=%t.d/o
// RUN: cd %t.d && { %kairo -I s s/main.k --type-check-only > /dev/null 2> clean || true; }
// RUN: cmp %t.d/e %t.d/clean
//
// NONE: incremental: plan: re-check all {{[0-9]+}} modules (no record)
// PLAN: incremental: plan: re-check 2 of {{[0-9]+}} modules
// PLAN-NEXT: incremental: plan: lib: R0 edited
// PLAN-NEXT: incremental: plan: main: R6 body of mid#fn:bump<1>(C,T), whose file names a changed body
// PLAN-NEXT: incremental: plan: verified
//
// RUN: rm -rf %t.r && mkdir -p %t.r/p && cp -r %S/inputs/fixity %t.r/p/s
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.r/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --script %S/inputs/fixity.replay --scratch %t.r/scratch | %FileCheck %s --check-prefix=REPLAY --implicit-check-not=DIFFERS
//
// REPLAY: step 0 initial: full (the first check) {{.*}} ok
// REPLAY: step 1 op_body: refresh {{.*}} ok
// REPLAY: step 2 op_body_back: refresh {{.*}} ok
