/// std/iter.k

import builtin::base::cmp::*
import builtin::base::ops::*
import builtin::base::copy::*
import builtin::base::hash::*
import builtin::base::iter::*
import builtin::string::*

/// Callbacks are `fn` values: one indirect call per element, no inlining.
/// Fine for most code; a callable-interface bound will replace them later.

/// Adapters live on a wrapper until interfaces get blanket extends.
/// An Iter is used once: an adapter moves the inner iterator out.
/// Start from a generator: `iter(v.iter())`, `iter(s.lines())`.
pub class <I impl Iterator> Iter {
    priv var it: I
}

pub fn <I impl Iterator> iter(it: I) -> Iter<I> = Iter<I> { it: it }

extend <I impl Iterator> Iter<I> impl Iterator {
    type Item = I::Item
    fn next(self) -> I::Item? {
        __builtin_trap() // BODY-TODO
    }
}

extend <I impl Iterator> Iter<I> {
    pub fn <U> map(self, f: fn(I::Item) -> U) -> Iter<Map<I, U>> {
        __builtin_trap() // BODY-TODO
    }
    pub fn filter(self, f: fn(*const I::Item) -> bool) -> Iter<Filter<I>> {
        __builtin_trap() // BODY-TODO
    }
    pub fn <U> filter_map(self, f: fn(I::Item) -> U?) -> Iter<FilterMap<I, U>> {
        __builtin_trap() // BODY-TODO
    }
    pub fn <J impl Iterator> flat_map(self, f: fn(I::Item) -> J) -> Iter<FlatMap<I, J>> {
        __builtin_trap() // BODY-TODO
    }
    pub fn enumerate(self) -> Iter<Enumerate<I>> {
        __builtin_trap() // BODY-TODO
    }
    pub fn <J impl Iterator> zip(self, other: J) -> Iter<Zip<I, J>> {
        __builtin_trap() // BODY-TODO
    }
    pub fn <J impl Iterator> chain(self, other: J) -> Iter<Chain<I, J>> requires __builtin_is_same<J::Item, I::Item>() {
        __builtin_trap() // BODY-TODO
    }
    pub fn take(self, n: usize) -> Iter<Take<I>> {
        __builtin_trap() // BODY-TODO
    }
    pub fn skip(self, n: usize) -> Iter<Skip<I>> {
        __builtin_trap() // BODY-TODO
    }
    pub fn take_while(self, f: fn(*const I::Item) -> bool) -> Iter<TakeWhile<I>> {
        __builtin_trap() // BODY-TODO
    }
    pub fn skip_while(self, f: fn(*const I::Item) -> bool) -> Iter<SkipWhile<I>> {
        __builtin_trap() // BODY-TODO
    }
    pub fn step_by(self, n: usize) -> Iter<StepBy<I>> {
        __builtin_trap() // BODY-TODO
    }
    pub fn peekable(self) -> Iter<Peekable<I>> {
        __builtin_trap() // BODY-TODO
    }

    pub fn <C impl FromIterator<I::Item>> collect(self) -> C {
        __builtin_trap() // BODY-TODO
    }
    pub fn <A> fold(self, init: A, f: fn(A, I::Item) -> A) -> A {
        __builtin_trap() // BODY-TODO
    }
    pub fn reduce(self, f: fn(I::Item, I::Item) -> I::Item) -> I::Item? {
        __builtin_trap() // BODY-TODO
    }
    pub fn count(self) -> usize {
        __builtin_trap() // BODY-TODO
    }
    pub fn last(self) -> I::Item? {
        __builtin_trap() // BODY-TODO
    }
    pub fn nth(self, n: usize) -> I::Item? {
        __builtin_trap() // BODY-TODO
    }
    pub fn find(self, f: fn(*const I::Item) -> bool) -> I::Item? {
        __builtin_trap() // BODY-TODO
    }
    pub fn position(self, f: fn(*const I::Item) -> bool) -> usize? {
        __builtin_trap() // BODY-TODO
    }
    pub fn any(self, f: fn(*const I::Item) -> bool) -> bool {
        __builtin_trap() // BODY-TODO
    }
    pub fn all(self, f: fn(*const I::Item) -> bool) -> bool {
        __builtin_trap() // BODY-TODO
    }
    pub fn for_each(self, f: fn(I::Item)) {
        __builtin_trap() // BODY-TODO
    }
    pub fn partition(self, f: fn(*const I::Item) -> bool) -> ([I::Item], [I::Item]) {
        __builtin_trap() // BODY-TODO
    }
    pub fn <K impl Hash> group_by(self, key: fn(*const I::Item) -> K) -> {K: [I::Item]} {
        __builtin_trap() // BODY-TODO
    }
}

/// Chosen over the plain collect when the length is known: the target is sized once.
extend <I impl ExactSize> Iter<I> {
    pub fn <C impl FromIterator<I::Item>> collect(self) -> C {
        __builtin_trap() // BODY-TODO
    }
}

extend <I impl ExactSize> Iter<I> impl ExactSize {
    fn remaining(const self) -> usize {
        __builtin_trap() // BODY-TODO
    }
}

extend <I impl DoubleEnded> Iter<I> {
    pub fn rev(self) -> Iter<Rev<I>> {
        __builtin_trap() // BODY-TODO
    }
}

/// Container iteration yields pointers; this yields the elements.
extend <U impl Copyable> Iter<Yield<*const U>> {
    pub fn copied(self) -> Iter<Copied<U>> {
        __builtin_trap() // BODY-TODO
    }
}

extend <I impl Iterator> Iter<I> requires I::Item impl Ord {
    pub fn min(self) -> I::Item? {
        __builtin_trap() // BODY-TODO
    }
    pub fn max(self) -> I::Item? {
        __builtin_trap() // BODY-TODO
    }
    pub fn sorted(self) -> [I::Item] {
        __builtin_trap() // BODY-TODO
    }
}

extend <I impl Iterator> Iter<I> requires I::Item impl Hash {
    pub fn counts(self) -> {I::Item: usize} {
        __builtin_trap() // BODY-TODO
    }
}

extend <I impl Iterator> Iter<I> requires I::Item impl Add && I::Item impl Default {
    pub fn sum(self) -> I::Item {
        __builtin_trap() // BODY-TODO
    }
}

extend <I impl Iterator> Iter<I> requires I::Item impl Append {
    pub fn join(self, const sep: string = "") -> string {    // one buffer for the whole result
        __builtin_trap() // BODY-TODO
    }
}

pub class <I impl Iterator, U> Map { priv var it: I  priv var f: fn(I::Item) -> U }
extend <I impl Iterator, U> Map<I, U> impl Iterator { type Item = U  fn next(self) -> U? { __builtin_trap() } }  // BODY-TODO
extend <I impl ExactSize, U> Map<I, U> impl ExactSize { fn remaining(const self) -> usize { __builtin_trap() } }  // BODY-TODO

pub class <I impl Iterator> Filter { priv var it: I  priv var f: fn(*const I::Item) -> bool }
extend <I impl Iterator> Filter<I> impl Iterator { type Item = I::Item  fn next(self) -> I::Item? { __builtin_trap() } }  // BODY-TODO

pub class <I impl Iterator, U> FilterMap { priv var it: I  priv var f: fn(I::Item) -> U? }
extend <I impl Iterator, U> FilterMap<I, U> impl Iterator { type Item = U  fn next(self) -> U? { __builtin_trap() } }  // BODY-TODO

pub class <I impl Iterator, J impl Iterator> FlatMap { priv var it: I  priv var f: fn(I::Item) -> J  priv var cur: J? }
extend <I impl Iterator, J impl Iterator> FlatMap<I, J> impl Iterator { type Item = J::Item  fn next(self) -> J::Item? { __builtin_trap() } }  // BODY-TODO

pub class <I impl Iterator> Enumerate { priv var it: I  priv var i: usize }
extend <I impl Iterator> Enumerate<I> impl Iterator { type Item = (usize, I::Item)  fn next(self) -> (usize, I::Item)? { __builtin_trap() } }  // BODY-TODO
extend <I impl ExactSize> Enumerate<I> impl ExactSize { fn remaining(const self) -> usize { __builtin_trap() } }  // BODY-TODO

pub class <I impl Iterator, J impl Iterator> Zip { priv var a: I  priv var b: J }
extend <I impl Iterator, J impl Iterator> Zip<I, J> impl Iterator { type Item = (I::Item, J::Item)  fn next(self) -> (I::Item, J::Item)? { __builtin_trap() } }  // BODY-TODO

pub class <I impl Iterator, J impl Iterator> Chain requires __builtin_is_same<J::Item, I::Item>() { priv var a: I?  priv var b: J }
extend <I impl Iterator, J impl Iterator> Chain<I, J> impl Iterator { type Item = I::Item  fn next(self) -> I::Item? { __builtin_trap() } }  // BODY-TODO

pub class <I impl Iterator> Take { priv var it: I  priv var n: usize }
extend <I impl Iterator> Take<I> impl Iterator { type Item = I::Item  fn next(self) -> I::Item? { __builtin_trap() } }  // BODY-TODO

pub class <I impl Iterator> Skip { priv var it: I  priv var n: usize }
extend <I impl Iterator> Skip<I> impl Iterator { type Item = I::Item  fn next(self) -> I::Item? { __builtin_trap() } }  // BODY-TODO

pub class <I impl Iterator> TakeWhile { priv var it: I  priv var f: fn(*const I::Item) -> bool  priv var done: bool }
extend <I impl Iterator> TakeWhile<I> impl Iterator { type Item = I::Item  fn next(self) -> I::Item? { __builtin_trap() } }  // BODY-TODO

pub class <I impl Iterator> SkipWhile { priv var it: I  priv var f: fn(*const I::Item) -> bool  priv var done: bool }
extend <I impl Iterator> SkipWhile<I> impl Iterator { type Item = I::Item  fn next(self) -> I::Item? { __builtin_trap() } }  // BODY-TODO

pub class <I impl Iterator> StepBy { priv var it: I  priv var step: usize  priv var first: bool }
extend <I impl Iterator> StepBy<I> impl Iterator { type Item = I::Item  fn next(self) -> I::Item? { __builtin_trap() } }  // BODY-TODO

@no_warn(S055W)
pub class <I impl Iterator> Peekable { priv var it: I  priv var peeked: (I::Item?)? }
extend <I impl Iterator> Peekable<I> impl Iterator { type Item = I::Item  fn next(self) -> I::Item? { __builtin_trap() } }  // BODY-TODO
extend <I impl Iterator> Peekable<I> { pub fn peek(self) -> (*const I::Item)? { __builtin_trap() } }  // BODY-TODO

pub class <I impl DoubleEnded> Rev { priv var it: I }
extend <I impl DoubleEnded> Rev<I> impl DoubleEnded {
    type Item = I::Item
    fn next(self) -> I::Item? {
        __builtin_trap() // BODY-TODO
    }
    fn next_back(self) -> I::Item? {
        __builtin_trap() // BODY-TODO
    }
}
extend <I impl DoubleEnded> Rev<I> requires I impl ExactSize impl ExactSize { fn remaining(const self) -> usize { __builtin_trap() } }  // BODY-TODO

pub class <U impl Copyable> Copied { priv var it: Yield<*const U> }
extend <U impl Copyable> Copied<U> impl Iterator { type Item = U  fn next(self) -> U? { __builtin_trap() } }  // BODY-TODO
