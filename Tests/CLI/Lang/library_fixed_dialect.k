// Two dialect flags apply to the user's files only: Lib/builtin and
// Lib/std compile in one fixed mode whatever the user passes.
// The std root here is a scratch one; probe.k is compiled once as std and
// once, as a control, as the user's own file.
//
//   -funwind            a library function stays `noexcept` (unless it is
//                       marked `@unwind`); the user's copy loses it.
//   -fcxx-implicit-conv the library resolves a call into C++ without C++'s
//                       implicit user-defined conversion; the user's copy
//                       takes it.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: shell
// RUN: rm -rf %t.d && mkdir -p %t.d/std %t.d/user
// RUN: touch %t.d/std/module.k
// RUN: printf 'pub fn dflt(a: i32) -> i32 { return a * a }\n' > %t.d/std/probe.k
// RUN: cp %t.d/std/probe.k %t.d/user/probe.k
// RUN: printf '#pragma once\nstruct View { const char* p; View(const char* s) : p(s) {} };\ninline int len(View v) { return v.p[0]; }\n' > %t.d/view.h
// RUN: printf 'ffi "c++" import "%t.d/view.h"\n\npub fn n() -> i32 { return len("hello") }\n' > %t.d/std/conv.k
// RUN: cp %t.d/std/conv.k %t.d/user/conv.k
//
// RUN: { %kairo --std-dir=%t.d/std -funwind --print-ir %t.d/std/probe.k 2>&1 || true; } | %FileCheck %s --check-prefix=STD-UNWIND
// STD-UNWIND: signed int dflt(signed int a) noexcept {
// RUN: { %kairo --std-dir=%t.d/std -funwind --print-ir %t.d/user/probe.k 2>&1 || true; } | %FileCheck %s --check-prefix=USER-UNWIND
// USER-UNWIND: signed int dflt(signed int a) {
//
// RUN: { %kairo --std-dir=%t.d/std -fcxx-implicit-conv --type-check-only %t.d/std/conv.k 2>&1 || true; } | %FileCheck %s --check-prefix=STD-CONV
// STD-CONV: conv.k:3:28: error [SC063E]: no matching overload for call to 'len'
// RUN: %kairo --std-dir=%t.d/std -fcxx-implicit-conv --type-check-only %t.d/user/conv.k
