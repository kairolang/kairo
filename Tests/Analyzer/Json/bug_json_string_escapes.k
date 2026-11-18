// XFAIL: *
// RFC 8259 section 7 allows only the escapes \" \\ \/ \b \f \n \r \t \uXXXX
// and forbids raw U+0000 through U+001F in a string. The reader turns an
// unknown escape into the escaped character and copies raw control bytes,
// and it pairs a high-surrogate escape with any following \u escape.
// Cases: Analyzer/JsonTest.k, KnownStringRules.

import JsonTest::KnownStringRules

fn main() -> i32 {
    return KnownStringRules()
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -I %S/../../../Analyzer -o %t.exe --cache-dir %t.d/run
// RUN: %kairo %s -I %S/../../../Analyzer -O2 -o %t.o2.exe --cache-dir %t.d/run2
// RUN: %t.exe
// RUN: %t.o2.exe
