// A static requirement may return `Self?`. The nullable of the interface's
// own Self names no C++ type outside a witness, so declaring the interface
// instantiates nothing for it.

interface Parse {
    static fn parse(x: i32) -> Self?
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
