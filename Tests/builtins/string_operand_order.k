// `string` is a MOVE type in this library. An operand bound ahead of a
// later operand that is a call (`tr == text[..lo]` before a call in the
// same condition, `len_of(tr)` beside `tr.codepoints()`, `put(s, cap -
// s.size())`) is read in place, by reference, never copied.
fn len_of(const s: string) -> usize {
    return s.size()
}

fn put(const s: string, at: usize) -> usize {
    return s.size() + at
}

fn main() -> i32 {
    var text = "abcdef"
    var tr   = text.to_owned()
    var lo: usize = 3
    tr.truncate(lo)
    if !(tr == text[..lo]) || tr.codepoints() != len_of(tr) {
        return 1
    }

    return (put(tr, 10 - tr.size()) as i32) - 10
}

// --- lit wiring ---
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s
// CHECK-NOT:   error [
// CHECK-LABEL: int main() noexcept {
// CHECK:       auto && __kairo_ord{{[0-9]+}} =(tr);
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
