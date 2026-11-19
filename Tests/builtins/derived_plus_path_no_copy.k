// `dir + "/" + name` on move-only strings: `dir` is read for the last time,
// so it moves into the result and no `.copy()` is needed.
fn join(dir: string, const name: string) -> string {
    var path = dir + "/" + name
    return path
}

fn main() -> i32 {
    var p = join("usr", "lib")
    return (p.size() as i32) - 7
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error [
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
