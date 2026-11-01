// OperatorSemantics: a duck `<T: type>` division by zero is the same crash
// as a concrete one, at T = i32 and at a narrow T.

fn <T: type> rem(a: T, b: T) -> T = a % b
fn zero8() -> u8 { return 0 }

fn main() -> i32 {
    var a: u8 = 10
    return rem(a, zero8()) as i32
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe 2> %t.err; test $? -eq 134
// RUN: grep -q 'kairo: division by zero' %t.err
