// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 41
//
// A generic free function over an imported C++ container instance whose
// argument is a Kairo parameter (`cxx::std::vector<T>`). The pattern's
// signatures are dependent: `size_type` is `allocator_traits<A>::size_type`,
// opaque at the definition, and `[]`, `at`, `front` and `back` each have a
// const twin. Looking them up on the pattern would reject `v[i]` and
// `i < v.size()` (SC063E / SC066E) or report the const pair as ambiguous;
// each call is decided per instance instead, as C++ does.
// DIAG-NOT: error [
// DIAG-NOT: ffi type

ffi "c++" import "vector"
ffi "c++" import "map"
ffi "c++" import "deque"

fn <T> index(v: cxx::std::vector<T>, i: usize) -> T {
    return v[i]
}

fn <T> at(v: cxx::std::vector<T>, i: usize) -> T {
    return v.at(i)
}

fn <T> ends(v: cxx::std::vector<T>) -> T {
    return v.front() + v.back()
}

fn <T> count(v: cxx::std::vector<T>) -> usize {
    return v.size()
}

fn <T> has(v: cxx::std::vector<T>, i: usize) -> bool {
    return i < v.size()
}

fn <T> last(v: cxx::std::vector<T>) -> T {
    return v[v.size() - 1]
}

fn <T> through(v: *cxx::std::vector<T>) -> T {
    return v->front() + (*v)[0]
}

fn <T> local(x: T) -> T {
    var v: cxx::std::vector<T>
    v.push_back(x)
    const w = v
    return w[0] + w.front()
}

fn <K, V> lookup(m: cxx::std::map<K, V>, k: K) -> V {
    return m.at(k)
}

fn <T> both(d: cxx::std::deque<T>) -> T {
    return d[0] + d.back()
}

fn main() -> i32 {
    var v: cxx::std::vector<i32>
    v.push_back(1)
    v.push_back(2)
    v.push_back(3)
    var m: cxx::std::map<i32, i32>
    m[5] = 6
    var d: cxx::std::deque<i32>
    d.push_back(2)
    var r = index(v, 1) + at(v, 2) + ends(v) + (count(v) as i32) + last(v)
    if has(v, 2) && (!has(v, 3)) {
        r += 10
    }

    r += through(&v) + local(2) + lookup(m, 5) + both(d)
    return r
}
