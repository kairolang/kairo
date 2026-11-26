// RUN: { %kairo --print-tokens %s || true; } | %FileCheck %s
// RUN: { %kairo --dump-preprocessed %s || true; } | %FileCheck %s --check-prefix=PP

// embed_str! stands for a string literal whose immediate is a sentinel; the
// token dumps spell it as a marker instead of reading the string table.

// CHECK: identifier 's'
// CHECK: <embed_str>
// PP: embed_str

fn main() -> i32 {
    var s = embed_str!("x.txt")
    return 0
}
