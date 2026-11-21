// The moves that are not destructive keep C++'s rule: the moved-from
// object is destroyed at the end of its scope (ownership.mdx, Moved-From
// State; classes-lifecycle.mdx). A moved-from object of these types may
// still own something, so it is never left undestroyed:
//  - copy_class: a COPY class, whose transfer is a copy;
//  - cxx_class: an imported C++ class (its destructors are counted);
//  - holds_cxx: a Kairo class holding a C++ class by value;
//  - holds_copy: a class whose defaulted move copies a COPY field;
//  - move_param: a `@move` parameter, a reference to the caller's object.
// `-fno-destructive-moves` turns the rule off: then `probe`'s moved-from
// local is destroyed too, as C++ does it.
ffi "c++" import "destructive_moves_unchanged.hh"
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

class HoldsCxx {
    var c: DmCxx
    fn HoldsCxx(self, id: i32) { self.c = DmCxx(id) }
    @move fn HoldsCxx(self, other: Self) = default
}

class HoldsCp {
    var c: Cp
    fn HoldsCp(self, id: i32) { self.c = Cp(id) }
    @move fn HoldsCp(self, other: Self) = default
}

fn keep(@move r: Res) {
    var k = r
    println(f"kept {k.id}")
}

fn copy_class() {
    var a = Cp(1)
    var b = a
    println(f"copied {b.id}")
}

fn cxx_class() -> i32 {
    var before = dm_cxx_count()
    if true {
        var a = DmCxx(2)
        var b = a
    }
    return dm_cxx_count() - before
}

fn holds_cxx() -> i32 {
    var before = dm_cxx_count()
    if true {
        var a = HoldsCxx(3)
        var b = a
    }
    return dm_cxx_count() - before
}

fn holds_copy() {
    var a = HoldsCp(4)
    var b = a
    println("holds_copy end")
}

fn move_param() {
    var a = Res(5)
    keep(a)
    println("move_param end")
}

fn probe() {
    var a = Res(6)
    var b = a
    println("probe end")
}

fn main() -> i32 {
    copy_class()
    println(f"cxx {cxx_class()}")
    println(f"holds_cxx {holds_cxx()}")
    holds_copy()
    move_param()
    probe()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// Only `probe`'s local takes union storage.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: void copy_class() noexcept {
// CXX-NOT: __kairo_ul
// CXX-LABEL: void probe() noexcept {
// CXX: ::__kairo_ul< ::{{.*}}::Res> __k_s_a {

// REQUIRES: clang
// RUN: rm -rf %t.d %t.off.d
// RUN: rm -f %t.exe %t.off.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefixes=OUT,ON --match-full-lines
// RUN: %kairo %s -fno-destructive-moves -o %t.off.exe --cache-dir %t.off.d
// RUN: %t.off.exe | %FileCheck %s --check-prefixes=OUT,OFF --match-full-lines
// OUT:      copied 101
// OUT-NEXT: ~Cp 101
// OUT-NEXT: ~Cp 1
// OUT-NEXT: cxx 2
// OUT-NEXT: holds_cxx 3
// OUT-NEXT: ~Cp 4
// OUT-NEXT: ~Cp 104
// OUT-NEXT: holds_copy end
// OUT-NEXT: ~Cp 304
// OUT-NEXT: ~Cp 204
// OUT-NEXT: kept 5
// OUT-NEXT: ~Res 5
// OUT-NEXT: move_param end
// OUT-NEXT: ~Res 0
// ON-NEXT:  probe end
// ON-NEXT:  ~Res 6
// ON-EMPTY:
// OFF-NEXT: probe end
// OFF-NEXT: ~Res 6
// OFF-NEXT: ~Res 0
// OFF-EMPTY:
