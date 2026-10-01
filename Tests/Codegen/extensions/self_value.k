// self_value.k -- exit 3
struct P { var v: i32; }

extend P {
    fn copy(const self) -> P { return self; }
    fn same(const self, o: P) -> bool { return self.v == o.v; }
}

enum Dir derives u8 { North, South }

extend Dir {
    fn flip(const self) -> Dir {
        if self == Dir::North { return Dir::South; }
        return Dir::North;
    }
}

fn main() -> i32 {
    var a = P { v: 5 };
    var b = a.copy();
    b.v += 1;
    var r: i32 = 0;
    if (a.v == 5) && (b.v == 6)        { r += 1; }
    if a.same(a.copy())                { r += 1; }
    if Dir::North.flip() == Dir::South { r += 1; }
    return r;
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// `self` read as a value: returned, compared, in an enum's extension.
// CXX: __kairo_ext_P::copy(const::self_value::P * self) {
// CXX-NEXT: return(* self);
// CXX: if((* self) == ::self_value::Dir::North) {
// CXX: int main() {
// CXX: __kairo_ext_Dir::flip( ::__kairo_tmp( ::self_value::Dir::North))

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 3
