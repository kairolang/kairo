ffi "c++" import r"numeric"

fn main() -> i32 {
    return cxx::std::gcd(12, 18)
}

// A raw string is a header path: it spells the header's name as written
// (a Windows path keeps its backslashes), and the import declares what the
// header does.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 6
