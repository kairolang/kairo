// The two library shapes whose generators borrow a temporary of the `for`
// header: `lines` borrows its receiver, `split` its pattern (`const p: P`).
// Each temporary is a local of the loop's block, so it outlives the
// generator that reads it on every `resume`.
fn make_heap() -> string {
    var s = "line one\nline two".to_owned()
    s += "\nline three"
    return s
}

fn count_lines() -> usize {
    var n: usize = 0
    for *l in make_heap().lines() {
        n += l->size()
    }

    return n
}

fn count_pieces() -> i32 {
    var src = "k=v1;x=v22"
    var n   = 0
    for *p in src.split(';') {
        n += 1
    }

    return n
}

fn main() -> i32 {
    return (count_lines() as i32) + count_pieces()
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: { %kairo_new %s --print-ir 2>&1 || true; } | %FileCheck %s
// CHECK-NOT:   error [
// CHECK-LABEL: count_lines() noexcept {
// CHECK:       string __kairo_ord[[R:[0-9]+]] ={{ ?}}::for_header_temporaries::make_heap();
// CHECK-NEXT:  __kairo_it{{[0-9]+}} ={{.*}}lines((& __kairo_ord[[R]]));
// CHECK-LABEL: count_pieces() noexcept {
// CHECK:       char32_t __kairo_ord[[P:[0-9]+]] = U';';
// CHECK-NEXT:  __kairo_it{{[0-9]+}} ={{.*}}split<char32_t>((& src), __kairo_ord[[P]],
