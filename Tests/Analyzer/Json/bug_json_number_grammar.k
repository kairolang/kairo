// XFAIL: *
// RFC 8259 section 6 requires a digit after '-', after '.' and after 'e', and
// forbids a leading zero. The reader's digit loops accept zero digits and any
// number of leading zeros, so '01', '-', '1.', '1e' and '[-.5]' parse.
// Cases: Analyzer/JsonTest.k, KnownNumberGrammar.

import JsonTest::KnownNumberGrammar

fn main() -> i32 {
    return KnownNumberGrammar()
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -I %S/../../../Analyzer -o %t.exe --cache-dir %t.d/run
// RUN: %kairo %s -I %S/../../../Analyzer -O2 -o %t.o2.exe --cache-dir %t.d/run2
// RUN: %t.exe
// RUN: %t.o2.exe
