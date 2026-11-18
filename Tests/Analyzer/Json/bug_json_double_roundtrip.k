// XFAIL: *
// A double written by JsonWriter::num and read back is the same double, and
// every written number is JSON. The reader builds a fraction as a sum of
// digit * 0.1^k, so 0.1 is off by an ulp; the writer prints inf and nan as
// bare words.
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
