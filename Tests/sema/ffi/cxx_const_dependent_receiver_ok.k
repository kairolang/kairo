// Through a const object whose C++ class template type depends on a Kairo
// type parameter, the const overloads and static members still resolve, and
// a non-const method stays callable through a mutable object or pointer.
ffi "c++" import "inputs/const_dependent_receiver.h"
ffi "c++" import "vector"

fn <T> reads(const v: cxx::std::vector<T>) -> usize {
    var b = v.begin()
    var e = v.end()
    if v.empty() || b == e {
        return 0
    }

    var x = v.front()
    var y = v.at(0)
    var z = v[0]
    return v.size()
}

fn <T> grow(v: *cxx::std::vector<T>, x: T) {
    v->push_back(x)
}

fn <T> fresh(x: T) -> usize {
    var w = cxx::std::vector<T>()
    w.push_back(x)
    return w.size()
}

fn <T> peek(const b: Bag<T>) -> T {
    var n = b.count()
    return b.first()
}

class <T> Holder {
    var v: cxx::std::vector<T>

    fn add(self, x: T) {
        self.v.push_back(x)
    }

    fn count(const self) -> usize {
        return self.v.size()
    }
}

fn main() -> i32 {
    var v = cxx::std::vector<i32>()
    grow(&v, 7)
    var b = Bag<i32>()
    b.put(5)
    var h = Holder<i32>()
    h.add(1)
    h.add(2)
    if reads(v) != 1 || fresh(3) != 1 || peek(b) != 5 || h.count() != 2 {
        return 1
    }

    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='error ['
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
