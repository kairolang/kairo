// A literal is the borrowed constructor: static bytes, byte and codepoint
// counts, cap 0. Every escape the lexer accepts decodes here; adjacent parts
// are one literal; raw copies verbatim.

fn chk(c: bool) -> i32 { if c { return 1 } return 0 }

fn main() -> i32 {
    var s = "Hello, Kairo! 📣"            // 18 bytes, 15 codepoints
    var t = "a" "b"                       // 2, 2
    var u = "\x27\n\U0001F4E3"            // 1 + 1 + 4 bytes, 3 codepoints
    var r = r"\n"                         // 2 raw bytes
    // 18 + 15 + 2 + 6 + 3 + 2 + 1 == 47
    return ((s.len + s.cp_len + t.len + u.len + u.cp_len + r.len) as i32) + chk(s.cap == 0)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: CODEGEN C++: {{.*}}strings/literal.k
// IR: reinterpret_cast<const unsigned char *>("Hello, Kairo! \360\237\223\243"), 18, 15
// IR: reinterpret_cast<const unsigned char *>("ab"), 2, 2
// IR: reinterpret_cast<const unsigned char *>("'\012\360\237\223\243"), 6, 3
// IR: reinterpret_cast<const unsigned char *>("\\n"), 2, 2

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 47
