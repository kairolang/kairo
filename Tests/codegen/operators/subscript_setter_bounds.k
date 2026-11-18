// The setter form of `op []=` through a bound and in generic code.
//
//   - An interface may require the setter; a generic bounded by it stores
//     with `s[k] = v` through the interface's witness, whose member for
//     the setter is `__kairo_op_index_put`.
//   - A generic class's setter, stored through from a generic function
//     that names the instance.
//   - In C++ the setter is the member `__kairo_op_put`, beside
//     `__kairo_op_get`; it is called by that name.
// Each failing check returns its number.

interface Store {
    fn op [] (const self, i: usize) -> i32
    fn op []= (self, i: usize, v: i32)
}

class Arr impl Store {
    pub var d: [i32; 4]
    pub var puts: i32 = 0
    fn Arr(self) { }
    fn op [] (const self, i: usize) -> i32 { return self.d[i] }
    fn op []= (self, i: usize, v: i32) {
        self.puts += 1
        self.d[i] = v
    }
}

class <T> Box {
    pub var d: [T; 2]
    pub var puts: i32 = 0
    fn Box(self) { }
    fn op [] (const self, i: usize) -> *const T { return &self.d[i] }
    fn op []= (self, const i: usize, const v: T) {
        self.puts += 1
        self.d[i] = v
    }
}

fn <S impl Store> through_pointer(s: *S, v: i32) {
    (*s)[0] = v
}

fn <S impl Store> through_inout(@inout s: S, v: i32) -> i32 {
    s[1] = v
    return s[1]
}

fn <T> into_box(b: *Box<T>, v: T) {
    (*b)[1] = v
}

fn main() -> i32 {
    var a = Arr()
    through_pointer(&a, 5)
    if through_inout(&a, 6) != 6 { return 1 }
    if a.puts != 2 || a[0] != 5 || a[1] != 6 { return 2 }
    var b = Box<i64>()
    b[0] = 3
    into_box(&b, 4 as i64)
    if b.puts != 2 || b[0] != 3 || b[1] != 4 { return 3 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d --print-ir > %t.ir 2>&1
// RUN: %t.exe
// RUN: %FileCheck %s --check-prefix=IR < %t.ir
// IR-DAG: Store_witness<S>::__kairo_op_index_put((* s), 0, v);
// IR-DAG: void Arr::__kairo_op_put(decltype(sizeof(0)) i, signed int v) noexcept {
// IR-DAG: b.__kairo_op_put(0, 3);
// IR-NOT: operator[]({{.*}}signed int v)
