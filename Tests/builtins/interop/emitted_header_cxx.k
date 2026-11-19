// C++ that includes the header `--emit-headers` writes for a module passing
// `string` and `[i32]` by value, receives both by value and returns them,
// built and linked by kcc on the same library. The library's headers sit in
// include cycles (slice and vector, hash, string and errors/crash include
// each other), which emitted_headers_all.k checks file by file.
// abi_registers_x86_64.k proves the same passing through hand-written
// twins.

@no_inline pub fn echo_string(s: string) -> string {
    return s
}

@no_inline pub fn echo_vector(v: [i32]) -> [i32] {
    return v
}

pub fn make_string(n: i32) -> string {
    return f"string {n} long enough to be on the heap"
}

pub fn take_string(s: string) -> usize {
    return s.size()
}

// --- lit wiring ---
// REQUIRES: kcc
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h
// RUN: printf '#include "h/emitted_header_cxx.hh"\nusing S = ::builtin::string::string;\nusing V = ::builtin::containers::vector::Vector<int>;\nS pass_s(S s) { return s; }\nV pass_v(V v) { return v; }\nint main() { return emitted_header_cxx::take_string(pass_s(emitted_header_cxx::echo_string(emitted_header_cxx::make_string(3)))) == 38 ? 0 : 1; }\n' > %t.d/use.cc
// RUN: %kcc -std=c++23 -I %t.d -I %t.d/h %t.d/use.cc %s -o %t.exe
// RUN: %t.exe
