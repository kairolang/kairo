/// builtin/base/iter.k

import base::copy::*
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
///
/// `next` resumes the generator to its next `yield` and returns that value,
/// or null once the body has finished. Calling it again after the first
/// null resumes a finished coroutine, which is undefined: stop at the first
/// null, as a `for` loop does.
///
/// The value is moved out of the generator's frame. A `yield` of a
/// temporary loses nothing by it; a `yield` of one of the generator's own
/// variables leaves that variable moved-from when the generator resumes, as
/// a move-only item has to.
extend <T> Yield<T> impl Iterator {
    type Item = T
    fn next(self) -> T? {
        if self.resume() {
            return move(*self.current())
        }

        return null
    }
}
