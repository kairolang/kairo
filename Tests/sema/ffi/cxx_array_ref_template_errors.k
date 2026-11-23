// The rejections around a C++ array-reference template parameter: a
// non-const `(&)[N]` is `@inout` and needs the `&` marker and a mutable
// array of its element type; a `const (&)[N]` takes the array bare, as a
// `const T&` does, and its note does not call it `@inout`.

ffi "c++" import "cxx_array_ref_template.h"

fn main() {
    var   a: [u8; 16]
    var   w: [i32; 4]
    const k: [u8; 4]  = [1, 2, 3, 4]
    tf(a, 0)
    tf(&w, 0)
    tc(&a)
    tf(&k, 0)
    tc(w)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: cxx_array_ref_template_errors.k:12:8: error [SC097E]: argument to '@inout' parameter 'b' must be marked with '&'
// CHECK: fix-it:"{{.*}}cxx_array_ref_template_errors.k":{12:8-12:8}:"&"
// CHECK: cxx_array_ref_template_errors.k:13:5: error [SC063E]: no matching overload for call to 'tf'
// CHECK: note [I900N]: candidate not viable: parameter 'b' is '@inout' and needs a mutable lvalue of type '[u8; N]'; got '[i32; 4]'
// CHECK: cxx_array_ref_template_errors.k:14:5: error [SC063E]: no matching overload for call to 'tc'
// CHECK: note [I900N]: candidate not viable: cannot convert argument of type '*[u8; 16]' to parameter 'b' of type 'const [u8; N]&'
// CHECK: cxx_array_ref_template_errors.k:15:5: error [SC063E]: no matching overload for call to 'tf'
// CHECK: note [I900N]: candidate not viable: parameter 'b' is '@inout' and needs a mutable lvalue of type '[u8; N]'; got 'const [u8; 4]'
// CHECK: cxx_array_ref_template_errors.k:16:5: error [SC063E]: no matching overload for call to 'tc'
// CHECK: note [I900N]: candidate not viable: cannot convert argument of type '[i32; 4]' to parameter 'b' of type 'const [u8; N]&'
