// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9
//
// A class field of type cxx::std::map<K, V>. Reading its lifecycle facts
// fills the template arguments of what it holds, and libc++'s __tree is
// parameterized on `__value_type<K, V>`, a tag the header only declares.
// The fill REQUIRED that complete, and clang's "implicit instantiation of
// undefined template 'std::__value_type<int, int>'" came out as CL001E for
// a field nobody even used; a local map was fine. C++ never needs the tag
// complete, so neither does the fill.

ffi "c++" import "map"

class Holder {
    pub var m: cxx::std::map<i32, i32>
    fn put(self, k: i32, v: i32) { self.m[k] = v }
    fn get(self, k: i32) -> i32 { return self.m[k] }
}

fn main() -> i32 {
    var h: Holder
    h.put(1, 4)
    h.put(2, 5)
    return h.get(1) + h.get(2)
}

// DIAG-NOT: error
