// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
// REQUIRES: host-x86_64
//
// A GNU vector type imports as an opaque keyed by its
// canonical spelling, and TypeExport had no clang type to spell it back as.
// So `vector<__m128i>` never filled -- `v[0]` was SC063E against a
// `size_type` no argument converts to, and `v.size()` had no integer type --
// and `std::move(v)` of one never deduced, typing as
// `__libcpp_remove_reference_t<_Tp>&&` that no `__m128i&&` parameter takes.
// The clang type the opaque came from is now what it exports as.

ffi "c++" import "vector_type_template_arg.h"
ffi "c++" import "vector"
ffi "c++" import "utility"

fn in_vector(p: unsafe *const __m128i) -> i32 {
    var v: cxx::std::vector<__m128i>
    v.push_back(_mm_loadu_si128(p))
    v.push_back(vt_make())
    var n: usize = v.size()
    var w = v[0]
    var last = v[n - 1]
    return _mm_movemask_epi8(_mm_cmpeq_epi8(w, last)) + vt_use(v.back())
}

fn moved() -> i32 {
    var a = vt_make()
    var r = vt_take_rr(cxx::std::move(a))
    var b = vt_make()
    var s = vt_take(cxx::std::move(b))
    return (r & 1) + (s & 2) + vt_use(vt_make())
}

// Every byte of vt_make() is 0x41: equal lanes compare all-ones (0xFFFF
// movemask, +4) and its own movemask is 0 through each move (+3).
fn main() -> i32 {
    var w = vt_make()
    var n = 0
    if in_vector(unsafe &w) == 65535 { n += 4 }
    if moved() == 0 { n += 3 }
    return n
}

// DIAG-NOT: error [
