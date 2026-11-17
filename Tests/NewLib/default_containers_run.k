// Vector, HashMap and HashSet implement Default, so a map's place form
// `m[k]` inserts an empty container on a miss and the result is usable at once.

import std::io

fn <T impl Default> make() -> T {
    return T::make_default()
}

fn main() -> i32 {
    var scores: {string: [i32]}
    var names = ["bob", "alice", "bob", "carol", "alice", "bob"]
    var n = 0
    for *name in names {
        n += 1
        scores[*name].push(n)
    }
    io::println(f"scores {scores.size()}")
    for *k in ["bob", "alice", "carol"] {
        var *l? = scores.get(*k)
        if !l? {
            return 1
        }
        var s = ""
        for x in *l {
            s += f"{x} "
        }
        io::println(f"{*k}: {s}")
    }

    var m: {u64: {u64}}
    m[7].insert(1)
    m[7].insert(2)
    m[7].insert(1)
    m[9].insert(5)
    io::println(f"sets {m.size()} {m[7].size()} {m[9].size()}")

    var nested: {string: {string: i32}}
    nested["a"]["x"] += 1
    nested["a"]["x"] += 1
    nested["a"]["y"] += 5
    nested["b"]["x"] += 3
    io::println(f"nested {nested.size()} {nested["a"].size()} {nested["a"]["x"]} {nested["a"]["y"]} {nested["b"]["x"]}")

    var v: [i32] = make<[i32]>()
    var h: {u64: u64} = make<{u64: u64}>()
    var s: {string} = make<{string}>()
    io::println(f"made {v.size()} {h.size()} {s.size()}")

    var grid = [[i32]]::with_len(3)
    grid[1].push(4)
    io::println(f"grid {grid.size()} {grid[0].size()} {grid[1].size()}")
    grid.resize(5)
    io::println(f"resized {grid.size()} {grid[4].size()}")
    return 0
}

// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK: scores 3
// CHECK-NEXT: bob: 1 3 6
// CHECK-NEXT: alice: 2 5
// CHECK-NEXT: carol: 4
// CHECK-NEXT: sets 2 2 1
// CHECK-NEXT: nested 2 2 2 5 3
// CHECK-NEXT: made 0 0 0
// CHECK-NEXT: grid 3 0 1
// CHECK-NEXT: resized 5 0
