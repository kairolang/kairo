// The language server's JSON reader and writer (analyzer/Json.k) against the
// rules of RFC 8259: structure, literals, whitespace, numbers, strings and
// escapes, surrogate pairs, nesting depth (257 containers), truncation at
// every byte, and writer round trips. Every case is written by hand in
// analyzer/JsonTest.k and names the rule it rests on. The deviations of the
// reader from the RFC are the bug_json_*.k tests beside this file.

import JsonTest::Test

fn main() -> i32 {
    return Test()
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -I %S/../../../Analyzer -o %t.exe --cache-dir %t.d/run
// RUN: %kairo %s -I %S/../../../Analyzer -O2 -o %t.o2.exe --cache-dir %t.d/run2
// RUN: %t.exe | %FileCheck %s
// RUN: %t.o2.exe | %FileCheck %s
// CHECK: json: {{[0-9]+}} cases, 0 failed
