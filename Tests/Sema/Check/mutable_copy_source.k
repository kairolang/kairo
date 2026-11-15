pub class Box {
    pub var v: i32 = 0
    pub fn Box(self) = default

    @copy
    pub fn Box(self, other: Self) {
        self.v = other.v
    }

    pub fn Box(self, v: i32) {
        self.v = v
    }
}

class Holder {
    pub var b: Box
    pub fn Holder(self) = default
}

fn make() -> Box {
    return Box(3)
}

fn take(b: Box) -> i32 {
    return b.v
}

fn copy_const_param(const b: Box) -> i32 {
    var c = b
    return c.v
}

fn ret_local() -> Box {
    var b = Box(1)
    return b
}

fn ret_param(b: Box) -> Box {
    return b
}

fn main() -> i32 {
    var a = Box(1)
    a = Box(5)
    a = make()
    const k = Box(2)
    var c = k
    var s = take(k)
    a = k
    const h = Holder()
    var h2 = h
    return a.v + c.v + s + h2.b.v - 6
}

// --- lit wiring ---
// A class whose `@copy` takes a non-const `other` copies only from a
// non-const object that is not a temporary: each copy from a const object,
// each assignment of a temporary, and each returned local is a Kairo error
// with the `const` fix at the constructor, never a clang error.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// RUN: rm -rf %t && mkdir -p %t && cp %s %t/mc.k
// RUN: { %kairo %t/mc.k --type-check-only 2>&1 || true; } > %t/diag.txt
// RUN: python3 %S/../../../Scripts/apply_fixits.py --from %t/diag.txt 2>&1 | %FileCheck %s --check-prefix=APPLIED
// RUN: %kairo %t/mc.k -o %t/mc.exe --cache-dir %t/c
// RUN: %t/mc.exe
//
// CHECK: mutable_copy_source.k:29:13: error [SC302E]: cannot copy 'b' into 'c': it is const, and the copy constructor of 'Box' takes a non-const 'other' (C++ 'Box(Box&)'), and 'Box' has no move constructor
// CHECK-NEXT: fix-it:"{{.*}}mutable_copy_source.k":{6:22-6:22}:"const "
// CHECK-NEXT: mutable_copy_source.k:6:22: note [I900N]: the copy constructor of 'Box' is declared here; with 'const other' it copies from const objects and temporaries too
// CHECK: mutable_copy_source.k:35:12: error [SC302E]: cannot return 'b': C++ moves a returned local or by-value parameter, and the copy constructor of 'Box'
// CHECK: mutable_copy_source.k:39:12: error [SC302E]: cannot return 'b': C++ moves a returned local or by-value parameter
// CHECK: mutable_copy_source.k:44:9: error [SC302E]: cannot assign a temporary into 'a': the copy constructor of 'Box' takes a non-const 'other'
// CHECK: mutable_copy_source.k:45:9: error [SC302E]: cannot assign a temporary into 'a'
// CHECK: mutable_copy_source.k:47:13: error [SC302E]: cannot copy 'k' into 'c': it is const
// CHECK: mutable_copy_source.k:48:18: error [SC302E]: cannot copy 'k' into a by-value parameter: it is const
// CHECK: mutable_copy_source.k:49:9: error [SC302E]: cannot copy 'k' into 'a': it is const
// CHECK: mutable_copy_source.k:51:14: error [SC302E]: cannot copy 'h' into 'h2': it is const, and 'Holder' declares no copy constructor and its field 'b' is a 'Box', whose copy constructor takes a non-const 'other' (C++ 'Box(Box&)'), and 'Box' has no move constructor
// CHECK-NEXT: fix-it:"{{.*}}":{6:22-6:22}:"const "
//
// APPLIED: changed 1 file(s)
