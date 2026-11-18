// `<` between two cxx::std::strings is accepted, but a string against an
// integer finds no ordering operator and is an error at the use.

ffi "c++" import "string";

fn main() -> i32 {
    var a = cxx::std::string("a")
    var b = a < 1
    var c = a < cxx::std::string("b")
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: cxx_string_less_than_reject.k:8:13: error [SC063E]: no matching overload for call to 'op <=>'
