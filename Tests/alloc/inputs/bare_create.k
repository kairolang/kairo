// Driven by ../sugar_no_import.k: the sugar's lang-item binding does not
// leak the name. The `@destroy` below puts alloc.k in this file's graph,
// and `create` written by hand must still need its import.
class P { pub var a: i64  fn P(self, a: i64) { self.a = a } }

fn main() -> i32 {
    var *p = create<P>(1i64)
    @destroy p
    return 0
}
