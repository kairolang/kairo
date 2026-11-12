// Pointer captures of a DEFERRED script variable (its initializer runs at its
// line, so its storage is a `T?` and a closure's read is the checked place
// `*({ if !g? {...} &g })`, ScriptMode.md). `|*|` and `|*count|` view it as
// the pointer to the value: the checked place's address.
//
//

import std::io

fn start() -> i32 { return 5 }

var count = start()
var bump = fn ()|*| { *count += 1 }
bump()
var named = fn ()|*count| { *count += 10 }
named()
io::println(f"{count}")

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK: 16
