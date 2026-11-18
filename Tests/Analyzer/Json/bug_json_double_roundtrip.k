// A double written by JsonWriter::num and read back is the same double, and
// every written number is JSON: an infinity or a NaN is written as null.
// Cases: Analyzer/JsonTest.k, KnownDoubleRoundtrip.

import JsonTest::KnownDoubleRoundtrip

fn main() -> i32 {
    return KnownDoubleRoundtrip()
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -I %S/../../../Analyzer -o %t.exe --cache-dir %t.d/run
// RUN: %kairo %s -I %S/../../../Analyzer -O2 -o %t.o2.exe --cache-dir %t.d/run2
// RUN: %t.exe
// RUN: %t.o2.exe
