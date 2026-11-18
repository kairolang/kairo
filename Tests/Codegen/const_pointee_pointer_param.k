// `*const T` with T bound to a pointer type is a pointer to a const
// pointer (`X *const *`): the conformance witness and the class spell the
// requirement's parameter alike, so an instance over pointers compiles.

interface <T> Less {
    fn lt(const self, a: *const T, b: *const T) -> bool
}

class <T> ByAddr impl Less<T> {
    pub fn ByAddr(self) { }

    pub fn lt(const self, a: *const T, b: *const T) -> bool {
        return a != b
    }
}

fn <T, C impl Less<T>> first_less(const c: C, a: *const T, b: *const T) -> bool {
    return c.lt(a, b)
}

fn main() -> i32 {
    var arr: [i32; 2] = [1, 2]
    var p: *i32 = &arr[0]
    var q: *i32 = &arr[1]
    var r = first_less<*i32, ByAddr<*i32>>(ByAddr<*i32>(), const &p, const &q)
    return if (r) => (0) else => 1
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
