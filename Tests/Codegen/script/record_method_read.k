// A deferred global of record type, read from a method: the read is the
// guarded place form (the `unwrap!` lvalue), so a method can both read a
// field and write one through it, and main's own later reads see the
// write. Called before the line, the same method would abort.

import std::io::println

struct Counter {
    pub var n: i32 = 0
}

fn start() -> Counter { var c = Counter{}; c.n = 10; return c }

class Bumper {
    pub fn bump(self) -> i32 { counter.n = counter.n + 1; return counter.n }
}

var counter = start()
var b = Bumper{}
println(f"{b.bump()} {b.bump()}")
println(f"main sees {counter.n}")

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      Bumper::bump() noexcept {
// CXX:      ::builtin::unwrap_failed({{.*}}"script variable 'counter' used before its line ran ({{.*}}record_method_read.k:18)\012"
// CXX:      ::builtin::Nullable<{{.*}}Counter> counter =
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      11 12
// OUT-NEXT: main sees 12
