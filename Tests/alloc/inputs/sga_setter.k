// Sets the global allocator; imported by sga_two.k, whose own file does not.
import builtin::base::alloc::*
import inputs::sga_counting::*

@set_global_allocator(Counting)
pub fn setter_count() -> i32 { return count() }
