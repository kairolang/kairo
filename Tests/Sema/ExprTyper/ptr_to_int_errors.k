// A pointer converts to `usize` and to no other integer (casting.mdx, Pointer
// to integer): not u32 (narrower), and not u64, i64 or isize either, though
// they are as wide on this host -- usize is the one type that holds an
// address on every target. The fix-it is the spec's own two-step spelling,
// `p as usize as T`. A nullable pointer is not a pointer: it has to be
// unwrapped first, and has no cast to an integer at all.

fn main() -> i32 {
    var x: i32 = 5
    var *p = &x
    const *c = &x
    var a = p as u32
    var b = p as u64
    var d = c as i64
    var e = p as isize
    var ok = p as usize as u32          // the honest spelling: no error
    var n: (*i32)? = &x
    var f = n as usize
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:12:13: error [SC026E]: a pointer converts to 'usize' only; write 'as usize as u32' if you mean to narrow the address
// DIAG-NEXT: fix-it:"{{.*}}":{12:18-12:18}:"usize as "
// DIAG-NEXT: {{.*}}:12:13: note [I900N]: '*i32' is a pointer; its address is a 'usize', and narrowing that is an ordinary integer cast
// DIAG: {{.*}}:13:13: error [SC026E]: a pointer converts to 'usize' only; write 'as usize as u64' if you mean to narrow the address
// DIAG-NEXT: fix-it:"{{.*}}":{13:18-13:18}:"usize as "
// DIAG-NEXT: {{.*}}:13:13: note [I900N]: '*i32' is a pointer; its address is a 'usize', and narrowing that is an ordinary integer cast
// DIAG: {{.*}}:14:13: error [SC026E]: a pointer converts to 'usize' only; write 'as usize as i64' if you mean to narrow the address
// DIAG-NEXT: fix-it:"{{.*}}":{14:18-14:18}:"usize as "
// DIAG-NEXT: {{.*}}:14:13: note [I900N]: 'const *i32' is a pointer; its address is a 'usize', and narrowing that is an ordinary integer cast
// DIAG: {{.*}}:15:13: error [SC026E]: a pointer converts to 'usize' only; write 'as usize as isize' if you mean to narrow the address
// DIAG-NEXT: fix-it:"{{.*}}":{15:18-15:18}:"usize as "
// DIAG-NEXT: {{.*}}:15:13: note [I900N]: '*i32' is a pointer; its address is a 'usize', and narrowing that is an ordinary integer cast
// DIAG: {{.*}}:18:13: error [SC027E]: no conversion from '*i32?' to 'usize'
// END-GENERATED-CHECKS(DIAG)
