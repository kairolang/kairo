// RUN: %kfmt --stdout %s | diff -u %s -
// RUN: %kfmt --check %s
//
// `@assume(...)` keeps its `@` after a statement ending in `)`.

fn f(p: *const u8, len: usize) {
    unsafe {
        var word = *(&p as unsafe *const usize)
        @assume(word != 0 || len == 0)
    }
}
