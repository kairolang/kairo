// A local that is moved out on some paths and returned on the others is
// moved at every exit: its storage needs no flag (`__kairo_ul`, not
// `__kairo_ulf`), and no hook runs at the end of its scope. One that some
// exit leaves alive keeps the flag (kept). R counts what it makes and
// releases; the run ends `made == released`.
import std::io::println

var made: i32 = 0
var released: i32 = 0

class R {
    var id: i32 = 0
    fn R(self, id: i32) {
        self.id = id
        made += 1
    }
    @move fn R(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
    fn op finally(self) {
        if self.id != 0 {
            released += 1
        }
        println(f"~R {self.id}")
    }
}

fn take(r: R) { }

fn moved_or_returned(c: bool) -> R {
    var a = R(1)
    if c {
        take(a)
        return R(2)
    }
    return a
}

fn kept(c: bool) -> R {
    var a = R(3)
    if c {
        take(a)
        return R(4)
    }
    if !c {
        println("kept: alive")
    }
    return R(5)
}

fn main() -> i32 {
    if true { var r = moved_or_returned(true) }
    if true { var r = moved_or_returned(false) }
    if true { var r = kept(true) }
    if true { var r = kept(false) }
    println(f"made {made} released {released}")
    return if (made == released) => (0) else => 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: moved_or_returned(bool c) noexcept {
// CXX-NEXT: ::__kairo_ul< ::{{.*}}::R> __k_s_a {
// CXX-NOT: cleanup
// CXX: return static_cast< ::{{.*}}::R &&>(__k_s_a.v);
// CXX-LABEL: kept(bool c) noexcept {
// CXX-NEXT: ::__kairo_ulf< ::{{.*}}::R> __k_s_a {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      ~R 1
// OUT-NEXT: ~R 2
// OUT-NEXT: ~R 1
// OUT-NEXT: ~R 3
// OUT-NEXT: ~R 4
// OUT-NEXT: kept: alive
// OUT-NEXT: ~R 3
// OUT-NEXT: ~R 5
// OUT-NEXT: made 7 released 7
// OUT-EMPTY:
