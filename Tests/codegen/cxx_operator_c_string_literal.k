// A string literal at an imported operator's `const char *` parameter is
// the C string itself (c-cpp-calling.md), as it is at a call. `s += "ab"`
// selected std::string::operator+=(const char *) but emitted the literal as a
// builtin::string, which clang rejected.

ffi "c++" import "string"

fn main() -> i32 {
    var s: cxx::std::string = cxx::std::string()
    s += "ab"
    s += "c"
    return s.size() as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe; test $? -eq 3
