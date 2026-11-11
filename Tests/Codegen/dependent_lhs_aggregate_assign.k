// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
//
// `res[i] = ns::DR{...}` where `res` is a std::array whose element type
// is only known per instantiation types the right side (the assign
// does not return early on the unknown left type), so a C++ aggregate's named
// initializer reaches EmitIR typed.

ffi "c++" import "Inputs/o4_agg.h"
ffi "c++" import "array"

fn <eval N: usize> fill(p: *u8) -> cxx::std::array<ns::DR, N> {
    var res = cxx::std::array<ns::DR, N>()
    var out_i: usize = 0
    for var j: usize = 0; j < 2; ++j {
        res[out_i] = ns::DR{chr: 'a', len: unsafe p[j], ok: true}
        ++out_i
    }
    return res
}

fn main() -> i32 {
    var b: [u8; 2] = [7, 7]
    var r = fill<4>(&b[0])
    return r[1].len
}
