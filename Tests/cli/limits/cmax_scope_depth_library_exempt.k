// --cmax-scope-depth does not reach the builtin and std libraries. Appending
// to an owned string goes through the library's deepest code (the in-place
// extension of `string`), which nests well past the cap of 3 used here;
// this file itself nests 2 deep. The program builds and runs at that cap,
// with the library's bodies typed and lowered for this program's uses.

fn main() -> i32 {
    var s = "ab".copy()
    s.push_str("cd")
    s.push('e')
    return (s.size() as i32) - 5
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: %kairo --type-check-only --cmax-scope-depth=3 %s
// RUN: %kairo --cmax-scope-depth=3 %s -o %t.exe
// RUN: %t.exe
// RUN: rm -f %t.exe
