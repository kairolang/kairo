// One 16-byte object created and destroyed N times through the global
// allocator. Compare alloc.cc (malloc/free and new/delete) and alloc.rs (Box).
import builtin::base::alloc::*
ffi "c++" import "bench_env.h"
class P2 { var a: i64  var b: i64  fn P2(self, a: i64, b: i64) { self.a = a; self.b = b } }
static sink: i64 = 0
fn main() -> i32 {
    var n = bench_n()
    for var i = 0; i < n; i += 1 {
        var *p = create<P2>(i as i64, 2i64)
        sink += p->a
        destroy<P2>(p)
    }
    return 0
}
