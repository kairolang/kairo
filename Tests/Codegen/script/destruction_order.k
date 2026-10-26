// XFAIL: *
// Waiting on ScriptLowering being scheduled (Compiler/Sema/SCRIPT.md, the
// plumbing checklist): until it runs, a top-level statement reaches EmitIR
// and ICEs there. When this XPASSes, delete the XFAIL line and keep the runs.
//
// Deferred script variables are destroyed at main's exit, in reverse order
// of their lines, after main's last statement and before any C++ static
// destructor: the synthesized main's first statement is a `finally` that
// sets each one back to null, last first. A variable whose line never ran
// is null already and destroys nothing (`w3`, after the early return).
// The early `return` takes the same exit.

import std::io::println

class Widget {
    pub var id: i32
    pub fn Widget(self, id: i32) { self.id = id; println(f"make {id}") }
    @move fn Widget(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op delete(self) { if self.id != 0 { println(f"drop {self.id}") } }
}

fn quit() -> bool { return true }

var w1 = Widget(1)
var w2 = Widget(2)
println(f"body {w1.id} {w2.id}")
if quit() { return }
var w3 = Widget(3)
println("not reached")

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      make 1
// OUT-NEXT: make 2
// OUT-NEXT: body 1 2
// OUT-NEXT: drop 2
// OUT-NEXT: drop 1
// OUT-NOT:  {{.}}
