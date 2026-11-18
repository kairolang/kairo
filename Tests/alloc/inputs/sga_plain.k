// A file of the program compiled apart, without --global-allocator-set.
import builtin::base::alloc::*

pub fn plain_work() -> i64 {
    var *p = create<i64>(5i64)
    var v = *p
    destroy<i64>(p)
    return v
}
