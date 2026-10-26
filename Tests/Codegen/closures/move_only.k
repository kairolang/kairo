// A MOVE value captured by copy is moved into the closure (ownership.md,
// Default capture: "MOVE types are moved"), with no list or named in one:
// the closure owns it, the binding it came from is moved-from (reading it
// afterwards is SC052E, Sema/Check/closure_captures.k), and it is
// destroyed once, with the closure. Moving the closure (returning it)
// carries it along without a copy. A move-only `fn` value cannot be
// copied (move_only_copy.k).

import std::io::println

var live: i32 = 0

@move class Handle {
    pub var id: i32 = 0
    fn Handle(self, id: i32) { self.id = id; live += 1 }
    @move fn Handle(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op delete(self) { if self.id != 0 { live -= 1 } }
}

fn read_once() -> i32 {
    var h = Handle(5)
    var f = fn () -> i32 { return h.id }
    println(f"inside: live={live}")
    return f()
}

fn named() -> i32 {
    var h = Handle(6)
    var f = fn ()|h| -> i32 { return h.id * 2 }
    return f()
}

fn make() -> fn() -> i32 {
    var h = Handle(7)
    return fn () -> i32 { return h.id }
}

fn main() -> i32 {
    println(f"default: {read_once()} live={live}")
    println(f"named: {named()} live={live}")
    var m = make()
    println(f"returned: {m()} live={live}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      inside: live=1
// OUT-NEXT: default: 5 live=0
// OUT-NEXT: named: 12 live=0
// OUT-NEXT: returned: 7 live=1

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: own(new auto([h = static_cast<{{.*}}::move_only::Handle &&>(h)]() mutable->signed int {
