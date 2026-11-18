// A `test "name" { }` block is SC116E; it used to reach EmitIR as an internal
// error.
fn add(a: i32, b: i32) -> i32 { return a + b }

test "adds" {
    assert add(1, 2) == 3
}

fn main() -> i32 { return 0 }

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --implicit-check-not=I003E --implicit-check-not=internal
// CHECK: test_block_unsupported.k:5:1: error [SC116E]: a 'test' block is not yet supported
