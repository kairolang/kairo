import std::io

fn main() -> i32 {
    const r = stringify!(r"a\b" y)
    const f = stringify!(f"a{1}")
    io::println(r)
    io::println(f)
    return (r.size() + f.size()) as i32
}

// --- lit wiring -----------------------------------------------------------
// Stringify! spells its arguments as written, a string's prefix
// included. A prefixed string token's range starts at its quote (the prefix
// is its own token), so the slice taken from the first argument's range
// dropped the `r` and the `f`.
// RUN: %kairo %s --dump-preprocessed | %FileCheck %s --check-prefix=PP
// PP: const r = "r"a\b" y"
// PP: const f = "f"a{1}""
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: { %t.exe || true; } | %FileCheck %s --check-prefix=RUNOUT
// RUNOUT: r"a\b" y
// RUNOUT-NEXT: f"a{1}"
// RUN: %t.exe; test $? -eq 15
