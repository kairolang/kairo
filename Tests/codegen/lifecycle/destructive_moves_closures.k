// A closure that captures a local of a Kairo MOVE class by copy moves the
// value in (ownership.mdx): the capture is built where the closure is, and
// the moved-from local is not destroyed again at the end of its scope
// (Moved-From State). Res's move zeroes its source: a moved-from object
// that is still destroyed prints `~Res 0`, one never destroyed is a
// missing `~Res N`.
//  - built / one_path / in_loop / returned / passed / nested: moved into
//    the closure on every path, on one path, once per iteration from a
//    rebuilt local, into a returned closure, into one passed to a
//    function, into an outer closure that an inner one captures from.
// Unchanged: a COPY class captured by copy (copy_class), a `|*a|`
// capture, which points at the local and moves nothing (by_pointer), and
// a value moved out of a closure's own capture (nested's inner closure
// takes the outer one's; the outer closure destroys its moved-from member,
// the one `~Res 0`).
import std::io::println

class Res {
    var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    @move fn Res(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
    fn op finally(self) { println(f"~Res {self.id}") }
}

class Cp {
    var id: i32 = 0
    fn Cp(self, id: i32) { self.id = id }
    @copy fn Cp(self, const other: Self) { self.id = other.id + 100 }
    fn op finally(self) { println(f"~Cp {self.id}") }
}

fn call(f: fn() -> i32) -> i32 { return f() }

fn built() {
    var a = Res(80)
    var f = fn () -> i32 { return a.id }
    println(f"built {f()}")
}

fn one_path(c: bool) {
    var a = Res(81)
    if c {
        var f = fn () -> i32 { return a.id }
        println(f"one_path {f()}")
    }
    println("one_path end")
}

fn in_loop() {
    var a = Res(82)
    for i in 0..2 {
        var f = fn () -> i32 { return a.id }
        println(f"in_loop {f()}")
        a = Res(83 + i)
    }
    println("in_loop end")
}

fn returned() -> fn() -> i32 {
    var a = Res(85)
    return fn () -> i32 { return a.id }
}

fn passed() {
    var a = Res(86)
    println(f"passed {call(fn () -> i32 { return a.id })}")
    println("passed end")
}

fn nested() {
    var a = Res(87)
    var outer = fn () -> i32 {
        var inner = fn () -> i32 { return a.id }
        return inner()
    }
    println(f"nested {outer()}")
}

fn copy_class() {
    var a = Cp(1)
    var f = fn () -> i32 { return a.id }
    println(f"copy_class {f()}")
}

fn by_pointer() {
    var a = Res(88)
    var f = fn ()|*a| -> i32 { return a->id }
    println(f"by_pointer {f()}")
}

fn main() -> i32 {
    built()
    one_path(true)
    one_path(false)
    in_loop()
    if true {
        var g = returned()
        println(f"returned {g()}")
    }
    passed()
    nested()
    copy_class()
    by_pointer()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// Moved into the closure on every path: elided storage, a plain cast in
// the capture. On one path: the capture clears the flag.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: void built() noexcept {
// CXX: ::__kairo_ul< ::{{.*}}::Res> __k_s_a {
// CXX-NOT: cleanup
// CXX: [a = static_cast< ::{{.*}}::Res &&>(__k_s_a.v)]
// CXX-LABEL: void one_path(bool c) noexcept {
// CXX: ::__kairo_ulf< ::{{.*}}::Res> __k_s_a {
// CXX: [a =(__k_s_a.live = false, static_cast< ::{{.*}}::Res &&>(__k_s_a.s.v))]
// CXX-LABEL: void by_pointer() noexcept {
// CXX-NOT: __kairo_ul
// CXX: [a = & a]

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2.d
// RUN: %t.o2.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      built 80
// OUT-NEXT: ~Res 80
// OUT-NEXT: one_path 81
// OUT-NEXT: ~Res 81
// OUT-NEXT: one_path end
// OUT-NEXT: one_path end
// OUT-NEXT: ~Res 81
// OUT-NEXT: in_loop 82
// OUT-NEXT: ~Res 82
// OUT-NEXT: in_loop 83
// OUT-NEXT: ~Res 83
// OUT-NEXT: in_loop end
// OUT-NEXT: ~Res 84
// OUT-NEXT: returned 85
// OUT-NEXT: ~Res 85
// OUT-NEXT: ~Res 86
// OUT-NEXT: passed 86
// OUT-NEXT: passed end
// OUT-NEXT: ~Res 87
// OUT-NEXT: nested 87
// OUT-NEXT: ~Res 0
// OUT-NEXT: copy_class 101
// OUT-NEXT: ~Cp 101
// OUT-NEXT: ~Cp 1
// OUT-NEXT: by_pointer 88
// OUT-NEXT: ~Res 88
// OUT-EMPTY:
