// Allocates through Global and knows nothing of the allocator the program sets.
import builtin::base::alloc::*

pub fn lib_work() {
    var *p = create<i64>(5i64)
    destroy<i64>(p)
}
