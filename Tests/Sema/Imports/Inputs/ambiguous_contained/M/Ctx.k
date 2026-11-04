// Glob-imports A, so `BigInt` here is A's AND the builtin prelude's.
import M::A::*;
pub class Ctx {
    fn <T> alloc(self) -> unsafe *T { return unsafe (0 as unsafe *T); }
    fn <T> alloc_array(self, n: usize) -> unsafe *T { return unsafe (0 as unsafe *T); }
    fn h(self, n: usize) -> i32 { return 0; }
}
pub fn <T> free_alloc(n: usize) -> i32 { return 0; }
