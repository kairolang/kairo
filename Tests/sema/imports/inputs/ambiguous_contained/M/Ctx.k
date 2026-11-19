// Glob-imports A and B, so `BigInt` here is A's AND B's.
import M::A::*; import M::B::*;
pub class Ctx {
    pub fn <T> alloc(self) -> unsafe *T { return unsafe (0 as unsafe *T); }
    pub fn <T> alloc_array(self, n: usize) -> unsafe *T { return unsafe (0 as unsafe *T); }
    pub fn h(self, n: usize) -> i32 { return 0; }
}
pub fn <T> free_alloc(n: usize) -> i32 { return 0; }
