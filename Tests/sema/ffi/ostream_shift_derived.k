// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5
//
// `os << s` on a stream of a class DERIVED from basic_ostream (an
// ostringstream, an ofstream) with a std::string. The operator is
// `basic_ostream<C, T>& operator<<(basic_ostream<C, T>&, const
// basic_string<C, T, A>&)`: C and T come from the derived-to-base
// conversion, which only clang deduces, so the declared return type stayed
// dependent and the expression finished untyped -- an internal error ("BinaryOperatorExpr
// reached finish() in no terminal state"). The return type is clang's
// specialization's, as for a return type that is its SFINAE.

ffi "c++" import "sstream"
ffi "c++" import "string"

fn main() -> i32 {
    var os: cxx::std::ostringstream
    var s = cxx::std::to_string(12345 as i32)
    // The result is the stream itself (by reference), still good.
    if (os << s).good() { return 5 }
    return 1
}

// DIAG-NOT: error
