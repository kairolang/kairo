// A ranged `for` over an imported C++ template instance over the generic's
// own parameter (`cxx::std::vector<T>`) inside a generic Kairo fn: its
// begin()/end() are C++'s to pick per instance, so it is C++'s range-for.
//
// Covered: a copy binder,
// `*x` writing through, `_`, break/continue, a const parameter, `(k, v)` destructuring.

ffi "c++" import "vector"
ffi "c++" import "map"

fn <T> total(v: cxx::std::vector<T>) -> i32 {
    var n = 0
    for x in v {
        if x == 3 { continue }
        if x == 9 { break }
        n += x as i32
    }

    return n
}

fn <T> count(const v: cxx::std::vector<T>) -> i32 {
    var n = 0
    for _ in v { n += 1 }
    return n
}

fn <T> double_all(v: *cxx::std::vector<T>) {
    for *x in *v { *x = *x * 2 }
}

fn <K, V> sum_pairs(m: cxx::std::map<K, V>) -> i32 {
    var n = 0
    for (k, v) in m { n += (k * 10 + v) as i32 }
    return n
}

fn main() -> i32 {
    var m = cxx::std::map<i32, i32>()
    m[1] = 2
    m[3] = 4
    if sum_pairs(m) != 46 { return 4 }
    var v = cxx::std::vector<i32>()
    v.push_back(1)
    v.push_back(2)
    v.push_back(3)
    v.push_back(4)
    v.push_back(9)
    v.push_back(100)
    if total(v) != 7 { return 1 }
    if count(v) != 6 { return 2 }
    double_all(&v)
    if v[0] != 2 || v[5] != 200 { return 3 }
    return 0
}

// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
