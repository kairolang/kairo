// C++ that includes the header `--emit-headers` writes for a module passing
// `string` and `[i32]` by value, receives both by value and returns them.
// Expected to fail: the headers emitted for Lib/builtin2 do not compile
// (base/hash.hh instantiates `Slice<u8>` and `Vector<u8>` before their
// definitions, and string.hh names a `Chars::ptr` the record does not
// declare); the headers emitted for the same module over Lib/builtin do.
// abi_registers_x86_64.k proves the same passing through hand-written
// twins.
// XFAIL: *

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
// REQUIRES: newlib
// REQUIRES: kcc
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo_new %s --type-check-only --emit-headers %t.d/h
// RUN: printf '#include "h/emitted_header_cxx.hh"\nusing S = ::builtin::string::string;\nusing V = ::builtin::containers::vector::Vector<int>;\nS pass_s(S s) { return s; }\nV pass_v(V v) { return v; }\nint main() { return emitted_header_cxx::take_string(pass_s(emitted_header_cxx::echo_string(emitted_header_cxx::make_string(3)))) == 38 ? 0 : 1; }\n' > %t.d/use.cc
// RUN: %kcc -std=c++23 -I %t.d -I %t.d/h %t.d/use.cc %s -Xkairo --builtins-dir=%S/../../../Lib/builtin2 -Xkairo --std-dir=%S/../../../Lib/std2 -o %t.exe
// RUN: %t.exe
