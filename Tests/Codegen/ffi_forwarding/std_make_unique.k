// std::make_unique itself. libc++ declares three overloads told apart only
// by SFINAE on an `enable_if_t<...> = 0` parameter (single object, array of
// unknown bound, deleted array of known bound). Kairo's own deduction
// cannot evaluate the condition, so all three were viable and tied
// (SC064E); clang's deduction and substitution now remove the two whose
// condition fails (OverloadResolution::_clang_substitute), and the call
// is emitted with its written `<int>` though no Kairo instance exists for
// a template with a parameter only C++ fills. More shapes:
// Codegen/ffi_sfinae/.

ffi "c++" import "memory"

fn main() -> i32 {
    var up = cxx::std::make_unique<i32>(9)
    return *up
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9
