// The `inline` modifier must not shadow the ffi-block form: `inline` followed
// by a language string is still an ffi block, not a malformed function.
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
inline "c++" {
    int cxx_side() { return 1; }
}
