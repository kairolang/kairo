// No file of this program sets the global allocator.
import builtin::base::alloc::*

fn main() -> i32 {
    var *p = create<i64>(1i64)
    destroy<i64>(p)
    return 0
}
