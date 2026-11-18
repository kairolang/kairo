// An integer beyond i64 parses (RFC 8259 section 6 lets an implementation
// limit the range) and its integer view saturates instead of wrapping.
// Cases: Analyzer/JsonTest.k, KnownIntegerRange.

import JsonTest::KnownIntegerRange

fn main() -> i32 {
    return KnownIntegerRange()
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -I %S/../../../Analyzer -o %t.exe --cache-dir %t.d/run
// RUN: %kairo %s -I %S/../../../Analyzer -O2 -o %t.o2.exe --cache-dir %t.d/run2
// RUN: %t.exe
// RUN: %t.o2.exe
