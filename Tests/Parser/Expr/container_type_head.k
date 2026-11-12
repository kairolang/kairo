// A container type heads a `::` path in expression position: `[T]::name`,
// `{T}::name` and `{K: V}::name` name the builtin record the type spells,
// as `Vector<T>::name` does, and a user class named `Vector` does not
// capture it. List, set and map literals keep their parse.
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe

extend <T> [T] {
    pub static fn of_one(const x: T) -> [T] {
        var v: [T] = []
        v.push(x)
        return v
    }
}

extend <T> {T} {
    pub static fn tag() -> i32 {
        return 2
    }
}

extend <K, V> {K: V} {
    pub static fn tag() -> i32 {
        return 3
    }
}

class Vector { }

fn main() -> i32 {
    var v = [i32]::of_one(7)
    var w = [string]::of_one("x")
    var l = [1, 2][1]
    var s = {1, 2}
    var m = {1: 2}
    if v[0] != 7 {
        return 1
    }

    if w.size() != 1 {
        return 2
    }

    if {i32}::tag() != 2 {
        return 3
    }

    if {string: i32}::tag() != 3 {
        return 4
    }

    if s.size() != 2 || m.size() != 1 {
        return 5
    }

    return l - 2
}
