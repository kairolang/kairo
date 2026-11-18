// XFAIL: *
// RFC 8259 section 8.1: JSON text is UTF-8. The reader copies the bytes of a
// string unchecked, so overlong forms, lone continuation bytes, encoded
// surrogates and values above U+10FFFF parse.
// Cases: Analyzer/JsonTest.k, KnownInvalidUtf8.

import JsonTest::KnownInvalidUtf8

fn main() -> i32 {
    return KnownInvalidUtf8()
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -I %S/../../../Analyzer -o %t.exe --cache-dir %t.d/run
// RUN: %kairo %s -I %S/../../../Analyzer -O2 -o %t.o2.exe --cache-dir %t.d/run2
// RUN: %t.exe
// RUN: %t.o2.exe
