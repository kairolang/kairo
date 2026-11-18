// baz.k  a SECOND source module, deliberately overlapping bar for the
// collision cases:
//   pub fn  id<T>   same name as bar::id  -> two-wildcard FUNCTION UNION
//                   (one key, two fn-set targets, NO error)
//   pub class Box   same name as bar::Box -> two non-function targets under
//                   one key -> AMBIGUOUS import (R016)

pub fn <T> id(y: T) -> T {
    return y
}

pub class <T> Box {
    pub var slot: T

    pub fn Box(self, s: T) {
        self.slot = s
    }
}
