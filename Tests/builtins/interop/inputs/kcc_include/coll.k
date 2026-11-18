// Collections of the two-word library behind a C++ include: the host
// passes and receives each of them by value.
import std

pub fn words(n: i32) -> [string] {
    var out: [string] = []
    for var i = 0; i < n; ++i {
        out.push(f"w{i}")
    }

    return out
}

pub fn total(v: [string]) -> usize {
    var t: usize = 0
    for var i: usize = 0; i < v.size(); ++i {
        t += v[i].size()
    }

    return t
}

pub fn counts(v: [string]) -> {string: i32} {
    var m: {string: i32} = {}
    for var i: usize = 0; i < v.size(); ++i {
        m.insert(v[i].copy(), v[i].size() as i32)
    }

    return m
}

pub fn keys(m: {string: i32}, v: [string]) -> {string} {
    var s: {string} = {}
    for var i: usize = 0; i < v.size(); ++i {
        if m.contains(v[i]) {
            s.insert(v[i].copy())
        }
    }

    return s
}

pub fn first_two(v: [i32]) -> i32 {
    var sl: [const i32;] = v
    return sl[0] + sl[1]
}

pub fn set_size(s: {string}) -> usize {
    return s.size()
}

pub fn nums() -> [i32] {
    return [20, 22]
}
