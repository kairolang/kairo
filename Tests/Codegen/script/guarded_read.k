// XFAIL: *
// Waiting on ScriptLowering being scheduled (Compiler/Sema/SCRIPT.md, the
// plumbing checklist): until it runs, a top-level statement reaches EmitIR
// and ICEs there. When this XPASSes, delete the XFAIL line and keep the runs.
//
// A function that reads a deferred script variable reads it CHECKED: the
// call graph cannot prove the variable's line ran first. Here main calls
// `report` before `cfg`'s line, through `relay`, one call deeper than the
// compile-time check follows, so the guard fires at run time: it writes
// "script variable 'cfg' used before its line ran (<file>:<line>)" to
// stderr and aborts (SIGABRT, status 134), in every build mode, the
// `unwrap!` runtime (Lib/rt/unwrap.c). Nothing after the call runs.

import std::io::println

fn load() -> i32 { return 42 }
fn report() { println(f"cfg {cfg}") }
fn relay() { report() }

println("before")
relay()
println("not reached")
var cfg = load()

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
//
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      if( ::{{.*}}cfg.is_null()) {
// CXX-NEXT:     ::builtin::unwrap_failed({{.*}}"script variable 'cfg' used before its line ran ({{.*}}guarded_read.k:23)\012"{{.*}}, {{[0-9]+}});
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %FileCheck %s --check-prefix=ERR --match-full-lines < %t.err
// OUT:      before
// OUT-NOT:  not reached
// ERR:      script variable 'cfg' used before its line ran ({{.*}}guarded_read.k:23)
// ERR-NOT:  {{.}}
