// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s
//
// Extension blocks of one type in one file that do not declare one member
// twice: overloads split across blocks, generic blocks whose bounds differ
// (two constrained templates), a generic block beside an instance block, and
// same-named members in blocks of different modules. Each compiles and runs.

import std::io::println

interface Small {
    fn small(const self) -> i32
}

interface Large {
    fn large(const self) -> i32
}

class Counter { var n: i32 = 0 }

extend Counter {
    fn step(self) -> i32 {
        return self.n + 1
    }
}

extend Counter {
    fn step(self, by: i32) -> i32 {
        return self.n + by
    }
}

class <T> Box { var v: T }

extend <T impl Small> Box<T> {
    fn pick(self) -> i32 {
        return self.v.small()
    }
}

extend <T impl Large> Box<T> {
    fn pick(self) -> i32 {
        return self.v.large()
    }
}

extend <T> Box<T> {
    fn kind(self) -> i32 {
        return 1
    }
}

extend Box<i64> {
    fn kind(self) -> i32 {
        return 2
    }
}

struct Pebble { var w: i32 = 3 }
extend Pebble impl Small {
    fn small(const self) -> i32 {
        return self.w
    }
}

module left {
    pub class Item { pub var v: i32 = 5 }
    extend Item {
        pub fn get(self) -> i32 {
            return self.v
        }
    }
}

extend left::Item {
    fn get(self) -> i32 {
        return self.v * 10
    }
}

fn main() -> i32 {
    var c = Counter()
    println(f"{c.step()} {c.step(4)}")
    // CHECK: 1 4
    var b = Box<Pebble> { v: Pebble() }
    println(f"{b.pick()}")
    // CHECK: 3
    return 0
}
