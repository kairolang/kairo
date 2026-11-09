// An enumerator of an imported unnamed enum is spelled in the enum's
// enclosing scope (`::dg::err_x`), never under clang's printed
// `(unnamed enum at f.h:2:16)` segment, which is no C++ name.
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 14

ffi "c++" import "Inputs/o41_unnamed_enum.h"

fn main() -> i32 {
    return ((dg::err_x as u32) + (Hold::inner_k as u32) + (top_k as u32)) as i32;
}
