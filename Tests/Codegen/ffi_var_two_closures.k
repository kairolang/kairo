// O8: a C variable both <cstdio> and <string> reach (glibc's `extern FILE
// *stdout`) is one entity, not an overload set of two. Read as a value it
// used to reach codegen unpromoted ("EmitIR: unpromoted overload set").

ffi "c++" import "cstdio"
ffi "c++" import "string"

fn main() -> i32 {
    cxx::std::fflush(stdout)
    return 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe; test $? -eq 7
