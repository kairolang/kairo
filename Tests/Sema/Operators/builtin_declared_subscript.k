// A builtin type's own `op []` wins over its built-in subscript shape
// (RESOLUTION.md, "A builtin type's declared operator wins"). `op []` must
// be a member (SC055E in an extension), and Lib/builtin declares none and is
// not this test's to change, so the test builds a fixture builtin root: a
// copy of Lib/builtin with an `op []` added to the Vector and string
// declarations, found by what they say rather than by file name
// (Inputs/patch_builtin.py).
//
// string runs: its literal constructor has a body, and the fixture's
// `op []` answers one more than the byte, which the built-in shape (a
// `char`) never would. A vector has no constructor body yet, so `at` is
// compiled and linked but never called. With `op []` declared, a subscript
// none of its overloads takes is the ordinary overload error, never a
// silent fall back to the shape (BAD below).

fn at(v: [i32], i: usize) -> i32 {
    v[i] = v[i] + 1                             // a place: `*T` is an lvalue
    return v[i]
}

eval if defined!(BAD) {
    fn bad(v: [i32]) -> i32 { return v["x"] }
}

fn main() -> i32 {
    var s = "abc"
    var b: u8 = s[1]                            // 'b' + 1 = 99
    return (b as i32) - 90                          // 9
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t && mkdir -p %t
// RUN: cp -r %S/../../../Lib/builtin %t/builtin
// RUN: cp -r %S/../../../Lib/rt %t/rt
// RUN: python3 %S/Inputs/patch_builtin.py %t/builtin 'pub struct <T> Vector' %S/Inputs/vector_subscript.members
// RUN: python3 %S/Inputs/patch_builtin.py %t/builtin 'pub struct string' %S/Inputs/string_subscript.members

// RUN: { %kairo %s --builtins-dir=%t/builtin --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --builtins-dir=%t/builtin --type-check-only -DBAD 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: builtin_declared_subscript.k:22:38: error

// Both subscripts call the declared operator; neither is the built-in shape
// EmitIR refuses.
// RUN: { %kairo %s --builtins-dir=%t/builtin --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: Internal Compiler Error
// CXX: (v.operator[](i) =(v.operator[](i) + 1));
// CXX: unsigned char b = s.operator[](1);

// REQUIRES: clang
// RUN: %kairo %s --builtins-dir=%t/builtin -o %t/a.exe --cache-dir %t/cache
// RUN: %t/a.exe; test $? -eq 9
