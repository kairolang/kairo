// A script's slice literal binding. The binding is deferred (a list
// literal is not a constant initializer, ScriptMode.md), so its initializer
// runs at its line inside the synthesized main as `s = [a, a + 1]`, and the
// backing array is a local of main spliced ahead of that assignment: it is
// built at that line, after `a` is set, and lives as long as main. Another
// function reads the global through it. ListLiteralLowering has a
// statement to put the backing in front of.

import std::io

fn second() -> i32 { return s[1] }

var a = 5
io::println("start")
var s: [i32;] = [a, a + 1, a * 3]
a = 100
io::println(f"{s[0]} {second()} {s[2]}")

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      start
// OUT-NEXT: 5 6 15
