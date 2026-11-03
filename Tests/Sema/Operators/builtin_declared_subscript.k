// A builtin type's own `op []` wins over its built-in subscript shape
// (RESOLUTION.md, "A builtin type's declared operator wins"). `op []` must
// be a member (SC055E in an extension). Both builtins here declare their
// own in Lib/builtin: Vector (containers/vector.k) and string (string.k, a
// byte place, `*u8` / `*const u8`), so no fixture root is needed any more.
//
// string runs: its `op []` is the byte, a `u8`, where the built-in shape (a
// `char`) would not even convert. `at` is compiled and linked but never
// called. With `op []` declared, a subscript none of its overloads takes is
// the ordinary overload error, never a silent fall back to the shape (BAD
// below). The BAD check names a line, so code above it keeps its place;
// Inputs/patch_builtin.py is what a fixture root would use.

fn at(@inout v: [i32], i: usize) -> i32 {
    v[i] = v[i] + 1                             // a place: `*T` is an lvalue
    return v[i]
}

eval if defined!(BAD) {
    fn bad(v: [i32]) -> i32 { return v["x"] }
}

fn main() -> i32 {
    var s = "abc"
    var b: u8 = s[1]                            // 'b' = 98
    return (b as i32) - 89                      // 9
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t && mkdir -p %t
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --type-check-only -DBAD 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: builtin_declared_subscript.k:20:38: error

// Both subscripts call the declared operator; neither is the built-in shape
// EmitIR refuses.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: Internal Compiler Error
// The place is evaluated first, bound once (SequenceLowering).
// CXX: auto && __kairo_ord0 =(v.operator[](i));
// CXX-NEXT: (__kairo_ord0 = static_cast<signed int>(static_cast<unsigned int>(v.operator[](i)) + static_cast<unsigned int>(1)));
// CXX: unsigned char b = s.operator[](1);

// REQUIRES: clang
// RUN: %kairo %s -o %t/a.exe --cache-dir %t/cache
// RUN: %t/a.exe; test $? -eq 9
