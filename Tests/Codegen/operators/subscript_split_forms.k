// The split subscript through generics, interfaces, structs,
// extensions, closures, loops and sub-range bindings, at run time. As in
// subscript_split_run.k each type's read form hands out other storage than
// its place form, so a check observes which form ran; each failing check
// returns its own number.
//
//   - `S impl Store` (both forms required) writes through the place form's
//     witness, `__kairo_op_index_set`, and reads through the read form's
//     (rows 82, 84); `S impl ReadOnly` (`op []` only) reads.
//   - A struct declares both forms (struct bodies take operators).
//   - A method writes and reads `self.t[i]` (the receiver is `self`'s field),
//     and so does an `extend` block's method.
//   - A closure capturing by pointer writes through `(*t)[i]` (row 51).
//   - `x[i].arr[j] += 1` writes the outer element (row 40).
//   - A sub-range: `var t = v[0..2]` on a mutable `v` binds the place form,,
//     `const u = v[1..3]` the read form; `for e in v[...]` reads,
//     `for *p in v[...]` writes (rows 48, 49, 66-68). Its read form takes
//     `self` beside a `self` place form of the same index type: one C++
//     overload, so C++ gets `operator[]` for the place form only.
//   - A class with only today's `op [] (self) -> *T` is unchanged: one
//     `operator[]` in C++, reads and writes through it.

interface Store {
    fn op [] (const self, i: usize) -> *const i32
    fn op []= (self, i: usize) -> *i32
}

interface ReadOnly {
    fn op [] (const self, i: usize) -> *const i32
}

class Two impl Store, ReadOnly {
    var r: [i32; 4]
    var w: [i32; 4]
    fn Two(self) {
        self.r = [10, 20, 30, 40]
        self.w = [0, 0, 0, 0]
    }

    fn op [] (const self, i: usize) -> *const i32 { return &self.r[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.w[i] }
}

struct SPair {
    var r: [i32; 2]
    var w: [i32; 2]
    fn op [] (const self, i: usize) -> *const i32 { return &self.r[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.w[i] }
}

class Arrs {
    var arr: [i32; 2]
    fn Arrs(self) { self.arr = [0, 0] }
}

class Rows {
    var r: [Arrs; 2]
    var w: [Arrs; 2]
    fn Rows(self) { }
    fn op [] (const self, i: usize) -> *const Arrs { return &self.r[i] }
    fn op []= (self, i: usize) -> *Arrs { return &self.w[i] }
}

class View {
    var d: [i32; 4]
    var e: [i32; 4]
    fn View(self) {
        self.d = [1, 2, 3, 4]
        self.e = [5, 6, 7, 8]
    }

    fn op [] (self, r: Range<usize>) -> [i32;] { return self.e[r.begin..r.end] }
    fn op []= (self, r: Range<usize>) -> [i32;] { return self.d[r.begin..r.end] }
}

class Legacy {
    var d: [i32; 2]
    fn Legacy(self) { self.d = [1, 2] }
    fn op [] (self, i: usize) -> *i32 { return &self.d[i] }
}

class Holder {
    var t: Two
    fn Holder(self) { }
    fn poke(self) { self.t[0] = 77 }
    fn peek(const self) -> i32 { return self.t[0] }
}

extend Holder {
    fn poke2(self) { self.t[1] = 66 }
    fn peek2(const self) -> i32 { return self.t[1] }
}

fn <S impl Store> put(s: *S, v: i32) -> i32 {
    (*s)[1] = v
    return (*s)[1]
}

fn <S impl ReadOnly> get(s: *S) -> i32 {
    return (*s)[2]
}

fn main() -> i32 {
    var t = Two()
    if put(&t, 5) != 20 { return 1 }
    if t.w[1] != 5 { return 2 }
    if get(&t) != 30 { return 3 }

    var sp = SPair { r: [1, 2], w: [0, 0] }
    sp[0] = 9
    if sp.w[0] != 9 || sp[0] != 1 { return 4 }

    var h = Holder()
    h.poke()
    if h.t.w[0] != 77 || h.peek() != 10 { return 5 }
    h.poke2()
    if h.t.w[1] != 66 || h.peek2() != 20 { return 6 }

    var f = fn () |*| { (*t)[2] = 3 }
    f()
    if t.w[2] != 3 { return 7 }

    var n: i32 = 0
    for var i: usize = 0; i < 4; ++i {
        n += t[i]
    }

    if n != 100 { return 8 }

    var rows = Rows()
    rows[1].arr[0] += 4
    if rows.w[1].arr[0] != 4 || rows[1].arr[0] != 0 { return 9 }

    var v = View()
    var s = v[0..2]
    s[0] = 9
    if v.d[0] != 9 { return 10 }
    const u = v[1..3]
    if u[0] != 6 { return 11 }
    var m: i32 = 0
    for e in v[0..4] {
        m += e
    }

    if m != 26 { return 12 }
    for *p in v[2..4] {
        *p = 0
    }

    if v.d[2] != 0 || v.d[3] != 0 || v.e[2] != 7 { return 13 }

    var lg = Legacy()
    lg[0] = 5
    if lg[0] != 5 || lg.d[0] != 5 { return 14 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: {{error|warning}}
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      class Two {
// CXX:        __kairo_op_get(decltype(sizeof(0)) i) const noexcept;
// CXX:        __kairo_op_set(decltype(sizeof(0)) i) noexcept;
// CXX:        signed int& operator[](decltype(sizeof(0)) i) noexcept;
// CXX:        const signed int& operator[](decltype(sizeof(0)) i) const noexcept;
// CXX:      class View {
// CXX:        __kairo_op_get({{.*}}Range<decltype(sizeof(0))> r) noexcept;
// CXX:        __kairo_op_set({{.*}}Range<decltype(sizeof(0))> r) noexcept;
// CXX-NEXT:   ::builtin::containers::slice::Slice<signed int> operator[]({{.*}}Range<decltype(sizeof(0))> r) noexcept;
// CXX-NOT:    operator[]
// CXX:      class Legacy {
// CXX-NOT:    __kairo_op
// CXX:        signed int& operator[](decltype(sizeof(0)) i) noexcept;
// CXX:      };
// RUN: { %kairo %s --print-ir -o %t.ir.exe 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-DAG: Store_witness<S>::__kairo_op_index_set((* s), 1) = v
// IR-DAG: return{{ *}}::{{.*}}Store_witness<S>::__kairo_op_index((* s), 1)
// IR-DAG: Slice<signed int> s = v.__kairo_op_set(
// IR-DAG: Slice<signed int> u = v.__kairo_op_get(
// IR-DAG: (lg.operator[](0) = 5)
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
