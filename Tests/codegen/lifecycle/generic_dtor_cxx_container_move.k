// A generic class with a destructor and no transfer constructor over a C++
// container of its parameter: its category is each instance's. `Bag<Mv>`
// holds a `vector<Mv>`, which C++'s traits call copyable, but Kairo says
// MOVE: the instance has exactly the move pair, and moves. `Bag<i32>` is
// COPY and copies.

ffi "c++" import "vector"

var drops: i32 = 0

class Mv {
    pub var n: i32 = 0
    fn Mv(self, n: i32) {
        self.n = n
    }

    @move fn Mv(self, other: Self) {
        self.n  = other.n
        other.n = 0
    }
}

class <T> Bag {
    pub var items: cxx::std::vector<T>
    fn Bag(self) { }
    fn op finally(self) {
        drops += 1
    }
}

fn take(b: Bag<Mv>) -> i32 {
    return b.items[0].n
}

fn main() -> i32 {
    var b = Bag<Mv>()
    b.items.push_back(Mv(7))
    if take(b) != 7 { return 1 }

    var c = Bag<i32>()
    c.items.push_back(3)
    var d = c
    if d.items[0] + c.items[0] != 6 { return 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template{{ ?}}<class> inline constexpr bool __kairo_copy_Bag = true;
// CXX: Bag(const Bag{{ ?}}&) requires({{.*}}__kairo_copy_Bag<Bag>) = default;
// CXX: template{{ ?}}<> inline constexpr bool __kairo_copy_Bag<{{.*}}Bag<{{.*}}Mv>> = false;
// CXX-NOT: __kairo_copy_Bag<{{.*}}Bag<signed int>> = false
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
