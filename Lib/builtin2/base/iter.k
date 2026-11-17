/// builtin/base/iter.k

import base::intrinsics::*
import builtin::Null
import coro::generator::*

pub interface Iterator {
    type Item
    fn next(self) -> Self::Item?
}

pub interface DoubleEnded derives Iterator {
    fn next_back(self) -> Self::Item?
}

/// An iterator that knows how many items are left.
pub interface ExactSize derives Iterator {
    fn remaining(const self) -> usize
}

/// `hint` is a lower bound on the item count, 0 when unknown.
pub interface <T> FromIterator {
    static fn <J impl Iterator> from_iter(it:   J,
                                          hint: usize) -> Self requires __builtin_is_same<J::Item, T>()
}

/// Every generator is an Iterator, so `iter(xs.lines()).map(...)` works.
extend <T> Yield<T> impl Iterator {
    type Item = T
    fn next(self) -> T? {
        __builtin_trap() // BODY-TODO
    }
}
