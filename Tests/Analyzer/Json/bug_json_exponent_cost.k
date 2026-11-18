// The cost of reading a number is bounded by its length: '1e2147483647'
// (12 bytes) and '1e-2147483647' parse at once, and an exponent longer than
// any integer type still parses.
// Cases: Analyzer/JsonTest.k, KnownExponentCost.

import JsonTest::KnownExponentCost

fn main() -> i32 {
    return KnownExponentCost()
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -I %S/../../../Analyzer -o %t.exe --cache-dir %t.d/run
// RUN: %kairo %s -I %S/../../../Analyzer -O2 -o %t.o2.exe --cache-dir %t.d/run2
// RUN: timeout 3 %t.exe
// RUN: timeout 3 %t.o2.exe
