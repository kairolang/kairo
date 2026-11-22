/// std/iter.k

import builtin::base::cmp::*
import builtin::base::ops::*
import builtin::base::copy::*
import builtin::base::hash::*
import builtin::base::iter::*
import builtin::string::*

/// Callbacks are `fn` values: one indirect call per element unless the
/// optimizer sees the callee after the chain is inlined into its caller.
/// A callable-interface bound will replace them later.
///
/// Every adapter holds its inner iterator by value and is move-only when the
/// inner one is. None allocates. An adapter's `next` is called until it
/// first returns null and not after: a generator must not be resumed once it
/// has finished, and no adapter remembers the end for its inner iterator
/// unless its contract says so (`Chain`, `TakeWhile`, `Peekable`).

/// Adapters live on a wrapper until interfaces get blanket extends.
/// An Iter is used once: an adapter moves the inner iterator out.
/// Start from an iterator or a generator: `iter(v.iter())`, `iter(s.lines())`.
pub class <I impl Iterator> Iter {
    priv var it: I
}

pub inline fn <I impl Iterator> iter(it: I) -> Iter<I> = Iter<I> { it: it }

pub class <I impl Iterator, U> Map {
    priv var it: I
    priv var f:  fn(I::Item) -> U
}

extend <I impl Iterator, U> Map<I, U> impl Iterator {
    type Item = U
    inline fn next(self) -> U? {
        var x = self.it.next()
        if !x? {
            return null
        }

        return self.f(move(unwrap!(x)))
    }
}

extend <I impl DoubleEnded, U> Map<I, U> impl DoubleEnded {
    inline fn next_back(self) -> U? {
        var x = self.it.next_back()
        if !x? {
            return null
        }

        return self.f(move(unwrap!(x)))
    }
}

extend <I impl ExactSize, U> Map<I, U> impl ExactSize {
    inline fn remaining(const self) -> usize {
        return self.it.remaining()
    }
}

pub class <I impl Iterator> Filter {
    priv var it: I
    priv var f:  fn(*const I::Item) -> bool
}

extend <I impl Iterator> Filter<I> impl Iterator {
    type Item = I::Item
    inline fn next(self) -> I::Item? {
        loop {
            var x = self.it.next()
            if !x? {
                return null
            }

            var v = move(unwrap!(x))
            if self.f(&v) {
                return move(v)
            }
        }
    }
}

extend <I impl DoubleEnded> Filter<I> impl DoubleEnded {
    inline fn next_back(self) -> I::Item? {
        loop {
            var x = self.it.next_back()
            if !x? {
                return null
            }

            var v = move(unwrap!(x))
            if self.f(&v) {
                return move(v)
            }
        }
    }
}

pub class <I impl Iterator, U> FilterMap {
    priv var it: I
    priv var f:  fn(I::Item) -> U?
}

extend <I impl Iterator, U> FilterMap<I, U> impl Iterator {
    type Item = U
    inline fn next(self) -> U? {
        loop {
            var x = self.it.next()
            if !x? {
                return null
            }

            var y = self.f(move(unwrap!(x)))
            if y? {
                return move(y)
            }
        }
    }
}

/// `cur` is the sub-iterator being drained, null between two of them. It is
/// cleared when it ends, so what it owns is released before the next outer
/// item is pulled.
pub class <I impl Iterator, J impl Iterator> FlatMap {
    priv var it:  I
    priv var f:   fn(I::Item) -> J
    priv var cur: J?
}

extend <I impl Iterator, J impl Iterator> FlatMap<I, J> impl Iterator {
    type Item = J::Item
    inline fn next(self) -> J::Item? {
        loop {
            if self.cur? {
                var y = unwrap!(self.cur).next()
                if y? {
                    return move(y)
                }

                self.cur = null
            }

            var x = self.it.next()
            if !x? {
                return null
            }

            self.cur = self.f(move(unwrap!(x)))
        }
    }
}

pub class <I impl Iterator> Enumerate {
    priv var it: I
    priv var i:  usize
}

extend <I impl Iterator> Enumerate<I> impl Iterator {
    type Item = (usize, I::Item)
    inline fn next(self) -> (usize, I::Item)? {
        var x = self.it.next()
        if !x? {
            return null
        }

        var i = self.i
        self.i = i + 1
        return (i, move(unwrap!(x)))
    }
}

extend <I impl ExactSize> Enumerate<I> impl ExactSize {
    inline fn remaining(const self) -> usize {
        return self.it.remaining()
    }
}

/// From the back an item's index is counted from the length.
extend <I impl DoubleEnded> Enumerate<I> impl DoubleEnded requires I impl ExactSize {
    inline fn next_back(self) -> (usize, I::Item)? {
        var x = self.it.next_back()
        if !x? {
            return null
        }

        return (self.i + self.it.remaining(), move(unwrap!(x)))
    }
}

/// Ends with the shorter side. `a` is pulled first; when `b` has ended the
/// item pulled from `a` is dropped.
pub class <I impl Iterator, J impl Iterator> Zip {
    priv var a: I
    priv var b: J
}

extend <I impl Iterator, J impl Iterator> Zip<I, J> impl Iterator {
    type Item = (I::Item, J::Item)
    inline fn next(self) -> (I::Item, J::Item)? {
        var x = self.a.next()
        if !x? {
            return null
        }

        var y = self.b.next()
        if !y? {
            return null
        }

        return (move(unwrap!(x)), move(unwrap!(y)))
    }
}

extend <I impl ExactSize, J impl ExactSize> Zip<I, J> impl ExactSize {
    inline fn remaining(const self) -> usize {
        var n = self.a.remaining()
        var m = self.b.remaining()
        return if n < m => n else => m
    }
}

/// From the back the longer side first drops what has no partner.
extend <I impl DoubleEnded, J impl DoubleEnded> Zip<I, J> impl DoubleEnded requires I impl ExactSize && J impl ExactSize {
    inline fn next_back(self) -> (I::Item, J::Item)? {
        var n = self.a.remaining()
        var m = self.b.remaining()
        while n > m {
            var dropped = self.a.next_back()
            n -= 1
        }

        while m > n {
            var dropped = self.b.next_back()
            m -= 1
        }

        var x = self.a.next_back()
        if !x? {
            return null
        }

        var y = self.b.next_back()
        if !y? {
            return null
        }

        return (move(unwrap!(x)), move(unwrap!(y)))
    }
}

/// `a` is null once it has ended: it is destroyed then, not when the chain
/// is, and it is never asked again.
pub class <I impl Iterator, J impl Iterator> Chain requires __builtin_is_same<J::Item, I::Item>() {
    priv var a: I?
    priv var b: J
}

extend <I impl Iterator, J impl Iterator> Chain<I, J> impl Iterator {
    type Item = I::Item
    inline fn next(self) -> I::Item? {
        if self.a? {
            var x = unwrap!(self.a).next()
            if x? {
                return move(x)
            }

            self.a = null
        }

        return self.b.next()
    }
}

/// From the back `b` is drained first. `b` is not cleared when it ends, so
/// a `b` that must not be asked again after its end is the caller's to stop
/// at: a chain read from both ends stops at the first null.
extend <I impl DoubleEnded, J impl DoubleEnded> Chain<I, J> impl DoubleEnded {
    inline fn next_back(self) -> I::Item? {
        var y = self.b.next_back()
        if y? {
            return move(y)
        }

        if self.a? {
            return unwrap!(self.a).next_back()
        }

        return null
    }
}

/// `n` is how many items are still to be passed on. At zero the inner
/// iterator is not asked: the item after the last one taken is never pulled.
pub class <I impl Iterator> Take {
    priv var it: I
    priv var n:  usize
}

extend <I impl Iterator> Take<I> impl Iterator {
    type Item = I::Item
    inline fn next(self) -> I::Item? {
        if self.n == 0 {
            return null
        }

        self.n -= 1
        return self.it.next()
    }
}

extend <I impl ExactSize> Take<I> impl ExactSize {
    inline fn remaining(const self) -> usize {
        var m = self.it.remaining()
        return if self.n < m => self.n else => m
    }
}

/// From the back the items past the cut are dropped first.
extend <I impl DoubleEnded> Take<I> impl DoubleEnded requires I impl ExactSize {
    inline fn next_back(self) -> I::Item? {
        if self.n == 0 {
            return null
        }

        var m = self.it.remaining()
        while m > self.n {
            var dropped = self.it.next_back()
            m -= 1
        }

        if m == 0 {
            return null
        }

        self.n = m - 1
        return self.it.next_back()
    }
}

/// `n` is how many items are still to be discarded; the first `next` discards
/// them.
pub class <I impl Iterator> Skip {
    priv var it: I
    priv var n:  usize
}

extend <I impl Iterator> Skip<I> impl Iterator {
    type Item = I::Item
    inline fn next(self) -> I::Item? {
        // One call site for the inner `next`: a second one doubles the code
        // every adapter below this one inlines here.
        loop {
            var x = self.it.next()
            if !x? {
                self.n = 0
                return null
            }

            if self.n == 0 {
                return move(x)
            }

            self.n -= 1
        }
    }
}

extend <I impl ExactSize> Skip<I> impl ExactSize {
    inline fn remaining(const self) -> usize {
        var m = self.it.remaining()
        return if m > self.n => m - self.n else => 0
    }
}

/// From the back the items still to be discarded are never reached.
extend <I impl DoubleEnded> Skip<I> impl DoubleEnded requires I impl ExactSize {
    inline fn next_back(self) -> I::Item? {
        if self.it.remaining() <= self.n {
            return null
        }

        return self.it.next_back()
    }
}

/// `done` is set by the first item the predicate refuses and by the inner
/// iterator's end: nothing is pulled after either.
pub class <I impl Iterator> TakeWhile {
    priv var it:   I
    priv var f:    fn(*const I::Item) -> bool
    priv var done: bool
}

extend <I impl Iterator> TakeWhile<I> impl Iterator {
    type Item = I::Item
    inline fn next(self) -> I::Item? {
        if self.done {
            return null
        }

        var x = self.it.next()
        if x? {
            var v = move(unwrap!(x))
            if self.f(&v) {
                return move(v)
            }
        }

        self.done = true
        return null
    }
}

/// `done` is set once the skipping is over: by the first item the predicate
/// refuses, which is the first item passed on.
pub class <I impl Iterator> SkipWhile {
    priv var it:   I
    priv var f:    fn(*const I::Item) -> bool
    priv var done: bool
}

extend <I impl Iterator> SkipWhile<I> impl Iterator {
    type Item = I::Item
    inline fn next(self) -> I::Item? {
        loop {
            var x = self.it.next()
            if !x? {
                return null
            }

            if self.done {
                return move(x)
            }

            var v = move(unwrap!(x))
            if !self.f(&v) {
                self.done = true
                return move(v)
            }
        }
    }
}

/// Passes on the first item and then every `step`-th. `step` is never zero:
/// `step_by(0)` traps.
pub class <I impl Iterator> StepBy {
    priv var it:    I
    priv var step:  usize
    priv var first: bool
}

extend <I impl Iterator> StepBy<I> impl Iterator {
    type Item = I::Item
    inline fn next(self) -> I::Item? {
        var k = if self.first => 0 as usize else => self.step - 1
        self.first = false
        loop {
            var x = self.it.next()
            if !x? {
                return null
            }

            if k == 0 {
                return move(x)
            }

            k -= 1
        }
    }
}

/// `peeked` is null when nothing is held, and holds what the inner `next`
/// returned otherwise: an item, or the null that ended it. A held end stays
/// held, so the inner iterator is never asked again after it.
@no_warn(S055W)
pub class <I impl Iterator> Peekable {
    priv var it:     I
    priv var peeked: (I::Item?)?
}

extend <I impl Iterator> Peekable<I> impl Iterator {
    type Item = I::Item
    inline fn next(self) -> I::Item? {
        if !self.peeked? {
            return self.it.next()
        }

        if !unwrap!(self.peeked)? {
            return null
        }

        var v: I::Item? = move(unwrap!(self.peeked))
        self.peeked = null
        return move(v)
    }
}

/// The address of the value held by the non-null nullable at `p`, from the
/// sizes of the nullable and of its value and the value's alignment.
///
/// COMPILER-WORKAROUND(nullable-payload-address): no expression names the
/// payload of a nullable as a place (`&unwrap!(x)` is the address of a
/// temporary), so the address is computed from the layout: a `T?` the size
/// of `T` is `T` itself with a spare value for null, and any other is one
/// tag byte, padding to `T`'s alignment, then `T`.
priv inline fn held_value(p: unsafe *const u8, whole: usize, value: usize, align: usize) -> unsafe *const u8 {
    unsafe {
        if whole != value {
            return p + align
        }

        return p
    }
}

@no_warn(S055W)
extend <I impl Iterator> Peekable<I> {
    /// The next item without consuming it, or null at the end. The pointer
    /// is valid until the next call on this iterator.
    pub inline fn peek(self) -> (*const I::Item)? {
        if !self.peeked? {
            var x: I::Item? = self.it.next()
            self.peeked = move(x)
        }

        unsafe {
            var unsafe *outer = held_value(
                &self.peeked as unsafe *const u8,
                sizeof((I::Item?)?),
                sizeof(I::Item?),
                alignof(I::Item?),
            ) as unsafe *const (I::Item?)

            if !(*outer)? {
                return null
            }

            return held_value(
                outer as unsafe *const u8,
                sizeof(I::Item?),
                sizeof(I::Item),
                alignof(I::Item),
            ) as unsafe *const I::Item as *const I::Item
        }
    }
}

pub class <I impl DoubleEnded> Rev {
    priv var it: I
}

extend <I impl DoubleEnded> Rev<I> impl DoubleEnded {
    type Item = I::Item
    inline fn next(self) -> I::Item? {
        return self.it.next_back()
    }
    inline fn next_back(self) -> I::Item? {
        return self.it.next()
    }
}

extend <I impl DoubleEnded> Rev<I> impl ExactSize requires I impl ExactSize {
    inline fn remaining(const self) -> usize {
        return self.it.remaining()
    }
}

/// The items a chain of pointers points at, copied.
///
/// The inner iterator is any whose items are `*const Target`: a slice's
/// `iter()`, a generator of pointers, or an adapter over one that passes
/// its items on unchanged.
///
/// COMPILER-WORKAROUND(derived-interface-item): the bound is `Iterator`, with
/// `PointerItems` stated in the clause. Under the bound `I impl
/// PointerItems` the clause's `I::Item` is not found, although the
/// interface derives `Iterator`. The item is bound to a `*const I::Target`
/// before it is read through: the clause makes the two one type, but not
/// one that `*` applies to.
pub class <I impl Iterator> Copied requires I impl PointerItems && I::Target impl Copyable && __builtin_is_same<I::Item, *const I::Target>() {
    priv var it: I
}

extend <I impl Iterator> Copied<I> impl Iterator requires I impl PointerItems && I::Target impl Copyable && __builtin_is_same<I::Item, *const I::Target>() {
    type Item = I::Target
    inline fn next(self) -> I::Target? {
        var p = self.it.next()
        if !p? {
            return null
        }

        var q: *const I::Target = unwrap!(p)
        eval if __builtin_is_integral<I::Target>() {
            return *q
        } else {
            return (*q).copy()
        }
    }
}

extend <I impl Iterator> Copied<I> impl DoubleEnded requires I impl DoubleEnded && I impl PointerItems && I::Target impl Copyable && __builtin_is_same<I::Item, *const I::Target>() {
    inline fn next_back(self) -> I::Target? {
        var p = self.it.next_back()
        if !p? {
            return null
        }

        var q: *const I::Target = unwrap!(p)
        eval if __builtin_is_integral<I::Target>() {
            return *q
        } else {
            return (*q).copy()
        }
    }
}

extend <I impl Iterator> Copied<I> impl ExactSize requires I impl ExactSize && I impl PointerItems && I::Target impl Copyable && __builtin_is_same<I::Item, *const I::Target>() {
    inline fn remaining(const self) -> usize {
        return self.it.remaining()
    }
}

/// A generator of pointers, as an iterator that says what they point at.
///
/// COMPILER-WORKAROUND(pattern-associated-type): `Yield<*const U>` does not
/// implement `PointerItems` itself. An associated type set from the
/// parameter of an extension's pattern (`extend <U> Yield<*const U> ...
/// type Target = U`) is emitted by that parameter's name in the witness of
/// a class over it, so `copied()` on a generator wraps it in this class,
/// whose own parameter is the target.
pub class <U> Pointed {
    priv var it: Yield<*const U>
}

extend <U> Pointed<U> impl Iterator {
    type Item = *const U
    inline fn next(self) -> (*const U)? {
        return self.it.next()
    }
}

extend <U> Pointed<U> impl PointerItems {
    type Target = U
}

// The adapters that pass their items on unchanged keep pointing at what
// their inner iterator points at.

extend <I impl PointerItems> Iter<I> impl PointerItems {
    type Target = I::Target
}

extend <I impl PointerItems> Filter<I> impl PointerItems {
    type Target = I::Target
}

extend <I impl PointerItems> Take<I> impl PointerItems {
    type Target = I::Target
}

extend <I impl PointerItems> Skip<I> impl PointerItems {
    type Target = I::Target
}

extend <I impl PointerItems> TakeWhile<I> impl PointerItems {
    type Target = I::Target
}

extend <I impl PointerItems> SkipWhile<I> impl PointerItems {
    type Target = I::Target
}

extend <I impl PointerItems> StepBy<I> impl PointerItems {
    type Target = I::Target
}

extend <I impl PointerItems> Peekable<I> impl PointerItems {
    type Target = I::Target
}

extend <I impl Iterator, J impl Iterator> Chain<I, J> impl PointerItems requires I impl PointerItems && J impl PointerItems {
    type Target = I::Target
}

extend <I impl DoubleEnded> Rev<I> impl PointerItems requires I impl PointerItems {
    type Target = I::Target
}

// --- internal iteration -----------------------------------------------------
//
// A consumer does not call `next` in a loop. It builds a sink, an object
// with one member that takes an item and says whether it wants another, and
// hands it to `Drive<I>::run`. Each adapter's `run` wraps the sink it is
// given in a sink of its own (a `Map` applies its function and passes the
// result on; a `Filter` passes on what its predicate holds for) and runs its
// inner iterator with that. The loop is written once, in the source, with the
// whole chain inlined into its body: a `filter` is a conditional inside one
// loop and not a loop of its own.
//
// `Drive<I>` is chosen per chain type by partial specialization. A generic
// body is checked against its bounds alone, so `Iter<I impl Iterator>` cannot
// ask its `I` for anything but `next`; the specialization for an adapter is
// what knows it. An iterator with no specialization (a generator, a user's
// class) gets the primary, whose `run` is the `next` loop.
//
// COMPILER-WORKAROUND(partial-bound): a partial specialization cannot carry
// a bound or a conformance clause, and its members get none from a member
// clause, so each partial is empty and derives a helper class that has the
// bounds and the members.
//
// COMPILER-WORKAROUND(sink-in-class): a sink conforms to `Sink` in its class
// body. A conformance written as `extend X<..> impl Sink<T>` has no witness
// in the unit that uses the chain.

/// Takes the items of a run. `put` moves the item out of `x` or leaves it to
/// its owner, and returns false to end the run.
///
/// COMPILER-WORKAROUND(interface-by-value): the item comes by reference. A
/// requirement that takes it by value is checked by copying it, which a
/// move-only item does not allow.
priv interface <T> Sink {
    fn put(self, @inout x: T) -> bool
}

/// How many items are left: at least `lo`, and exactly `lo` when `exact`.
/// Only sources and adapters of this file set `exact`, so it is safe to size
/// raw storage by it.
priv class Bound {
    var lo:    usize
    var exact: bool
}

priv inline fn least(a: usize, b: usize) -> usize {
    return if a < b => a else => b
}

priv class <I impl Iterator> Drive {
    /// Feeds `s` until the iterator ends or `s` refuses more. True when it
    /// was not `s` that ended the run: the iterator has nothing left, and a
    /// chain goes on to its next part. After false the iterator is where a
    /// `next` loop that stopped at the same item leaves it, and may be run
    /// or pulled again.
    static inline fn <S impl Sink<I::Item>> run(it: *I, s: *S) -> bool {
        loop {
            var x = it->next()
            if !x? {
                return true
            }

            var v = move(unwrap!(x))
            if !s->put(&v) {
                return false
            }
        }
    }

    static inline fn bound(it: *const I) -> Bound {
        return Bound { lo: 0, exact: false }
    }

    /// Makes the iterator end after at most `n` more items, when that takes
    /// no pass over them and skips no callback. False when it cannot.
    static inline fn limit(it: *I, n: usize) -> bool {
        return false
    }
}

/// `Drive` from the back.
priv class <I impl DoubleEnded> DriveBack {
    static inline fn <S impl Sink<I::Item>> run(it: *I, s: *S) -> bool {
        loop {
            var x = it->next_back()
            if !x? {
                return true
            }

            var v = move(unwrap!(x))
            if !s->put(&v) {
                return false
            }
        }
    }

    /// Keeps at most the last `n` items.
    static inline fn limit(it: *I, n: usize) -> bool {
        return false
    }
}

// --- sources ----------------------------------------------------------------

priv class <T> SliceDrive {
    /// An index loop over the elements left. A loop over `next` tests each
    /// result for null as well, which the optimizer does not fold into the
    /// end test: two exits where this has one.
    static inline fn <S impl Sink<*const T>> run(it: *SliceIter<T>, s: *S) -> bool {
        var left = it->as_slice()
        var n = left.size()
        var i: usize = 0
        while i < n {
            var q: *const T = &left[i]
            i += 1
            if !s->put(&q) {
                it->keep_last(n - i)
                return false
            }
        }

        it->keep_last(0)
        return true
    }

    static inline fn bound(it: *const SliceIter<T>) -> Bound {
        return Bound { lo: it->remaining(), exact: true }
    }

    static inline fn limit(it: *SliceIter<T>, n: usize) -> bool {
        it->keep_first(n)
        return true
    }
}

// COMPILER-WORKAROUND(partial-forward-decl): as for `Drive<Chain<I, J>>`,
// for a class of another module.
class <T> Drive<SliceIter<T>> derives SliceDrive<T> requires sizeof usize != 0 { }

priv class <T> SliceBackDrive {
    /// A pointer walked down from the end: one instruction an item less
    /// than an index counted down.
    static inline fn <S impl Sink<*const T>> run(it: *SliceIter<T>, s: *S) -> bool {
        var left = it->as_slice()
        var n = left.size()
        if n == 0 {
            return true
        }

        unsafe {
            var unsafe *first = &left[0] as unsafe *const T
            var unsafe *p = first + n
            while p != first {
                p = p - 1
                var q = p as *const T
                if !s->put(&q) {
                    it->keep_first(((p as usize) - (first as usize)) / sizeof T)
                    return false
                }
            }
        }

        it->keep_first(0)
        return true
    }

    static inline fn limit(it: *SliceIter<T>, n: usize) -> bool {
        it->keep_last(n)
        return true
    }
}

// COMPILER-WORKAROUND(partial-forward-decl): as for `Drive<Chain<I, J>>`,
// for a class of another module.
class <T> DriveBack<SliceIter<T>> derives SliceBackDrive<T> requires sizeof usize != 0 { }

priv class <T> SliceMutDrive {
    /// The loop runs on a copy of the two pointers, so they are the loop's
    /// own whatever becomes of the chain they come from.
    static inline fn <S impl Sink<*T>> run(it: *SliceIterMut<T>, s: *S) -> bool {
        var c = *it
        loop {
            var x = c.next()
            if !x? {
                *it = c
                return true
            }

            var q: *T = unwrap!(x)
            if !s->put(&q) {
                *it = c
                return false
            }
        }
    }

    static inline fn bound(it: *const SliceIterMut<T>) -> Bound {
        return Bound { lo: it->remaining(), exact: true }
    }

    static inline fn limit(it: *SliceIterMut<T>, n: usize) -> bool {
        it->keep_first(n)
        return true
    }
}

// COMPILER-WORKAROUND(partial-forward-decl): as for `Drive<Chain<I, J>>`,
// for a class of another module.
class <T> Drive<SliceIterMut<T>> derives SliceMutDrive<T> requires sizeof usize != 0 { }

priv class <T> SliceMutBackDrive {
    static inline fn <S impl Sink<*T>> run(it: *SliceIterMut<T>, s: *S) -> bool {
        var c = *it
        loop {
            var x = c.next_back()
            if !x? {
                *it = c
                return true
            }

            var q: *T = unwrap!(x)
            if !s->put(&q) {
                *it = c
                return false
            }
        }
    }

    static inline fn limit(it: *SliceIterMut<T>, n: usize) -> bool {
        it->keep_last(n)
        return true
    }
}

// COMPILER-WORKAROUND(partial-forward-decl): as for `Drive<Chain<I, J>>`,
// for a class of another module.
class <T> DriveBack<SliceIterMut<T>> derives SliceMutBackDrive<T> requires sizeof usize != 0 { }

// --- block scans ------------------------------------------------------------
//
// A scan that ends at the first item a predicate decides (`find`,
// `position`, `any`, `all`, `skip_while`, counting a `take_while`) is a loop
// with an exit in it, which the optimizer does not vectorize. Over a slice
// the same scan can test a block of elements with no exit inside the block:
// a countable loop, which it does vectorize. A block is tested whole, so the
// predicate also runs on elements past the one that ends the scan, and
// again on the block that holds it. Nothing can tell when both of these
// hold, and any other scan keeps the item loop alone, which calls the
// predicate once per item up to the one that ends the scan:
//
//   - the compiler vouches for the predicate (`__builtin_fn_speculatable`:
//     no effect, no trap, always returns, and it reads through no pointer
//     its argument does not reach);
//   - the elements are numbers, so what the argument reaches is the element
//     and nothing behind it. An element that holds a pointer may hold one
//     that is no longer valid past the element that ends the scan.
//
// `Blocks<I>` is chosen per chain type as `Drive<I>` is. The primary skips
// nothing, so a chain with no specialization is the item loop alone.
//
// The predicate is only seen where the chain is inlined into the code that
// names it. Anywhere else (an unoptimized build, a chain too large to
// inline) a block would be 32 calls for nothing, so the skip runs only
// where the optimizer has folded the predicate's verdict to a constant
// (`scan_ahead`). The same test keeps the skip out of the size the optimizer
// inlines by, which counts a branch on a `__builtin_constant_p` it cannot
// decide yet as not taken: a consumer is inlined where it was without one.

/// Elements a block scan tests at once. A scan that ends within its first
/// block pays for that block's test on top of the item loop.
priv eval SCAN_BLOCK: usize = 32
/// Elements a block scan tests one at a time before its first block, so a
/// scan that ends within them pays for no block. A slice with no room for
/// them and one block is left to the item loop.
priv eval SCAN_LEAD: usize = 8

/// True when a scan over elements of `T` may test `f` a block at a time.
priv inline fn <T, F> scan_ahead(f: *const F) -> bool {
    eval if __builtin_is_integral<T>() || __builtin_is_floating_point<T>() {
        var yes = __builtin_fn_speculatable(f)
        return __builtin_constant_p(yes) && yes
    } else {
        return false
    }
}

priv class <I impl Iterator> Blocks {
    /// Drops leading items for which `f` gives the opposite of `want`, never
    /// the first one for which it gives `want`. Returns how many it dropped.
    static inline fn skip(it: *I, f: *const (fn(*const I::Item) -> bool), want: bool) -> usize {
        return 0
    }

    /// The leading items a `count` may take from the chain unseen: none,
    /// unless counting them is all the chain does with them.
    static inline fn count(it: *I) -> usize {
        return 0
    }
}

/// `Blocks` from the back.
priv class <I impl DoubleEnded> BlocksBack {
    static inline fn skip(it: *I, f: *const (fn(*const I::Item) -> bool), want: bool) -> usize {
        return 0
    }
}

priv class <T> SliceBlocks {
    static inline fn skip(it: *SliceIter<T>, f: *const (fn(*const (*const T)) -> bool), want: bool) -> usize {
        if !scan_ahead<T, fn(*const (*const T)) -> bool>(f) {
            return 0
        }

        unsafe {
            var unsafe *lo = it->first_ptr()
            var unsafe *hi = it->end_ptr()
            var n = (hi - lo) as usize
            if n < SCAN_LEAD + SCAN_BLOCK {
                return 0
            }

            var k: usize = 0
            while k < SCAN_LEAD {
                var q = (lo + k) as *const T
                if (*f)(&q) == want {
                    *it = SliceIter<T>(lo + k, (hi - (lo + k)) as usize)
                    return k
                }

                k += 1
            }

            var unsafe *p = lo + SCAN_LEAD
            var blocks = (n - SCAN_LEAD) / SCAN_BLOCK
            while blocks != 0 {
                var hit = false
                k = 0
                while k < SCAN_BLOCK {
                    var q = (p + k) as *const T
                    hit |= (*f)(&q) == want
                    k += 1
                }

                if hit {
                    break
                }

                p = p + SCAN_BLOCK
                blocks -= 1
            }

            *it = SliceIter<T>(p, (hi - p) as usize)
            return (p - lo) as usize
        }
    }

    static inline fn count(it: *SliceIter<T>) -> usize {
        return 0
    }
}

// COMPILER-WORKAROUND(partial-forward-decl): as for `Drive<Chain<I, J>>`,
// for a class of another module.
class <T> Blocks<SliceIter<T>> derives SliceBlocks<T> requires sizeof usize != 0 { }

priv class <T> SliceBackBlocks {
    static inline fn skip(it: *SliceIter<T>, f: *const (fn(*const (*const T)) -> bool), want: bool) -> usize {
        if !scan_ahead<T, fn(*const (*const T)) -> bool>(f) {
            return 0
        }

        unsafe {
            var unsafe *lo = it->first_ptr()
            var unsafe *hi = it->end_ptr()
            var n = (hi - lo) as usize
            if n < SCAN_LEAD + SCAN_BLOCK {
                return 0
            }

            var k: usize = 1
            while k <= SCAN_LEAD {
                var q = (hi - k) as *const T
                if (*f)(&q) == want {
                    *it = SliceIter<T>(lo, n - (k - 1))
                    return k - 1
                }

                k += 1
            }

            var unsafe *p = hi - SCAN_LEAD
            var blocks = (n - SCAN_LEAD) / SCAN_BLOCK
            while blocks != 0 {
                var hit = false
                k = 1
                while k <= SCAN_BLOCK {
                    var q = (p - k) as *const T
                    hit |= (*f)(&q) == want
                    k += 1
                }

                if hit {
                    break
                }

                p = p - SCAN_BLOCK
                blocks -= 1
            }

            var done = (hi - p) as usize
            *it = SliceIter<T>(lo, n - done)
            return done
        }
    }
}

// COMPILER-WORKAROUND(partial-forward-decl): as for `Drive<Chain<I, J>>`,
// for a class of another module.
class <T> BlocksBack<SliceIter<T>> derives SliceBackBlocks<T> requires sizeof usize != 0 { }

priv class <I impl DoubleEnded> RevBlocks {
    static inline fn skip(it: *Rev<I>, f: *const (fn(*const I::Item) -> bool), want: bool) -> usize {
        return BlocksBack<I>::skip(&it->it, f, want)
    }

    static inline fn count(it: *Rev<I>) -> usize {
        return 0
    }
}

class <I> Blocks<Rev<I>> derives RevBlocks<I> { }

priv class <I impl Iterator> TakeWhileBlocks {
    static inline fn skip(it: *TakeWhile<I>, f: *const (fn(*const I::Item) -> bool), want: bool) -> usize {
        return 0
    }

    /// The items the predicate holds for are only counted, so the ones a
    /// block scan drops are counted here.
    static inline fn count(it: *TakeWhile<I>) -> usize {
        if it->done {
            return 0
        }

        return Blocks<I>::skip(&it->it, &it->f, false)
    }
}

class <I> Blocks<TakeWhile<I>> derives TakeWhileBlocks<I> { }

// --- adapters ---------------------------------------------------------------

priv class <I impl Iterator> IterDrive {
    static inline fn <S impl Sink<I::Item>> run(it: *Iter<I>, s: *S) -> bool {
        return Drive<I>::run<S>(&it->it, s)
    }

    static inline fn bound(it: *const Iter<I>) -> Bound {
        return Drive<I>::bound(&it->it)
    }

    static inline fn limit(it: *Iter<I>, n: usize) -> bool {
        return Drive<I>::limit(&it->it, n)
    }
}

class <I> Drive<Iter<I>> derives IterDrive<I> { }

priv class <I impl DoubleEnded> IterBackDrive {
    static inline fn <S impl Sink<I::Item>> run(it: *Iter<I>, s: *S) -> bool {
        return DriveBack<I>::run<S>(&it->it, s)
    }

    static inline fn limit(it: *Iter<I>, n: usize) -> bool {
        return DriveBack<I>::limit(&it->it, n)
    }
}

class <I> DriveBack<Iter<I>> derives IterBackDrive<I> { }

priv class <T, U, S impl Sink<U>> MapSink impl Sink<T> {
    var f:    *const (fn(T) -> U)
    var next: *S

    inline fn put(self, @inout x: T) -> bool {
        var y = (*self.f)(move(x))
        return self.next->put(&y)
    }
}

priv class <I impl Iterator, U> MapDrive {
    static inline fn <S impl Sink<U>> run(it: *Map<I, U>, s: *S) -> bool {
        var ms = MapSink<I::Item, U, S> { f: &it->f, next: s }
        return Drive<I>::run<MapSink<I::Item, U, S>>(&it->it, &ms)
    }

    static inline fn bound(it: *const Map<I, U>) -> Bound {
        return Drive<I>::bound(&it->it)
    }

    static inline fn limit(it: *Map<I, U>, n: usize) -> bool {
        return Drive<I>::limit(&it->it, n)
    }
}

class <I, U> Drive<Map<I, U>> derives MapDrive<I, U> { }

priv class <I impl DoubleEnded, U> MapBackDrive {
    static inline fn <S impl Sink<U>> run(it: *Map<I, U>, s: *S) -> bool {
        var ms = MapSink<I::Item, U, S> { f: &it->f, next: s }
        return DriveBack<I>::run<MapSink<I::Item, U, S>>(&it->it, &ms)
    }

    static inline fn limit(it: *Map<I, U>, n: usize) -> bool {
        return DriveBack<I>::limit(&it->it, n)
    }
}

class <I, U> DriveBack<Map<I, U>> derives MapBackDrive<I, U> { }

priv class <T, S impl Sink<T>> FilterSink impl Sink<T> {
    var f:    *const (fn(*const T) -> bool)
    var next: *S

    inline fn put(self, @inout x: T) -> bool {
        if (*self.f)(&x) {
            return self.next->put(&x)
        }

        return true
    }
}

priv class <I impl Iterator> FilterDrive {
    static inline fn <S impl Sink<I::Item>> run(it: *Filter<I>, s: *S) -> bool {
        var fs = FilterSink<I::Item, S> { f: &it->f, next: s }
        return Drive<I>::run<FilterSink<I::Item, S>>(&it->it, &fs)
    }

    static inline fn bound(it: *const Filter<I>) -> Bound {
        return Bound { lo: 0, exact: false }
    }

    static inline fn limit(it: *Filter<I>, n: usize) -> bool {
        return false
    }
}

class <I> Drive<Filter<I>> derives FilterDrive<I> { }

priv class <I impl DoubleEnded> FilterBackDrive {
    static inline fn <S impl Sink<I::Item>> run(it: *Filter<I>, s: *S) -> bool {
        var fs = FilterSink<I::Item, S> { f: &it->f, next: s }
        return DriveBack<I>::run<FilterSink<I::Item, S>>(&it->it, &fs)
    }

    static inline fn limit(it: *Filter<I>, n: usize) -> bool {
        return false
    }
}

class <I> DriveBack<Filter<I>> derives FilterBackDrive<I> { }

priv class <T, U, S impl Sink<U>> FilterMapSink impl Sink<T> {
    var f:    *const (fn(T) -> U?)
    var next: *S

    inline fn put(self, @inout x: T) -> bool {
        var y = (*self.f)(move(x))
        if y? {
            var v = move(unwrap!(y))
            return self.next->put(&v)
        }

        return true
    }
}

priv class <I impl Iterator, U> FilterMapDrive {
    static inline fn <S impl Sink<U>> run(it: *FilterMap<I, U>, s: *S) -> bool {
        var fs = FilterMapSink<I::Item, U, S> { f: &it->f, next: s }
        return Drive<I>::run<FilterMapSink<I::Item, U, S>>(&it->it, &fs)
    }

    static inline fn bound(it: *const FilterMap<I, U>) -> Bound {
        return Bound { lo: 0, exact: false }
    }

    static inline fn limit(it: *FilterMap<I, U>, n: usize) -> bool {
        return false
    }
}

class <I, U> Drive<FilterMap<I, U>> derives FilterMapDrive<I, U> { }

/// Runs each sub-iterator to its end before the next outer item is taken. A
/// sub-iterator the run stops in goes to `cur`, where `next` finds it.
priv class <T, J impl Iterator, S impl Sink<J::Item>> FlatMapSink impl Sink<T> {
    var f:    *const (fn(T) -> J)
    var cur:  *(J?)
    var next: *S

    inline fn put(self, @inout x: T) -> bool {
        var sub = (*self.f)(move(x))
        if !Drive<J>::run<S>(&sub, self.next) {
            *self.cur = move(sub)
            return false
        }

        return true
    }
}

priv class <I impl Iterator, J impl Iterator> FlatMapDrive {
    static inline fn <S impl Sink<J::Item>> run(it: *FlatMap<I, J>, s: *S) -> bool {
        if it->cur? {
            var c = move(unwrap!(it->cur))
            it->cur = null
            if !Drive<J>::run<S>(&c, s) {
                it->cur = move(c)
                return false
            }
        }

        var fs = FlatMapSink<I::Item, J, S> { f: &it->f, cur: &it->cur, next: s }
        return Drive<I>::run<FlatMapSink<I::Item, J, S>>(&it->it, &fs)
    }

    static inline fn bound(it: *const FlatMap<I, J>) -> Bound {
        return Bound { lo: 0, exact: false }
    }

    static inline fn limit(it: *FlatMap<I, J>, n: usize) -> bool {
        return false
    }
}

class <I, J> Drive<FlatMap<I, J>> derives FlatMapDrive<I, J> { }

priv class <T, S impl Sink<(usize, T)>> EnumerateSink impl Sink<T> {
    var i:    usize
    var next: *S

    inline fn put(self, @inout x: T) -> bool {
        var i = self.i
        self.i = i + 1
        var e = (i, move(x))
        return self.next->put(&e)
    }
}

priv class <I impl Iterator> EnumerateDrive {
    static inline fn <S impl Sink<(usize, I::Item)>> run(it: *Enumerate<I>, s: *S) -> bool {
        var es = EnumerateSink<I::Item, S> { i: it->i, next: s }
        var ended = Drive<I>::run<EnumerateSink<I::Item, S>>(&it->it, &es)
        it->i = es.i
        return ended
    }

    static inline fn bound(it: *const Enumerate<I>) -> Bound {
        return Drive<I>::bound(&it->it)
    }

    static inline fn limit(it: *Enumerate<I>, n: usize) -> bool {
        return Drive<I>::limit(&it->it, n)
    }
}

class <I> Drive<Enumerate<I>> derives EnumerateDrive<I> { }

/// `a` is run; `b` is pulled once per item of `a`. `refused` tells a run the
/// next sink ended from one `b` ended.
priv class <T, J impl Iterator, S impl Sink<(T, J::Item)>> ZipSink impl Sink<T> {
    var b:       *J
    var next:    *S
    var refused: bool

    inline fn put(self, @inout x: T) -> bool {
        var y = self.b->next()
        if !y? {
            return false
        }

        var e = (move(x), move(unwrap!(y)))
        if !self.next->put(&e) {
            self.refused = true
            return false
        }

        return true
    }
}

priv class <I impl Iterator, J impl Iterator> ZipDrive {
    static inline fn <S impl Sink<(I::Item, J::Item)>> run(it: *Zip<I, J>, s: *S) -> bool {
        var zs = ZipSink<I::Item, J, S> { b: &it->b, next: s, refused: false }
        Drive<I>::run<ZipSink<I::Item, J, S>>(&it->a, &zs)
        return !zs.refused
    }

    static inline fn bound(it: *const Zip<I, J>) -> Bound {
        var x = Drive<I>::bound(&it->a)
        var y = Drive<J>::bound(&it->b)
        return Bound { lo: least(x.lo, y.lo), exact: x.exact && y.exact }
    }

    /// `a` is pulled first, so its end is the pair's end.
    static inline fn limit(it: *Zip<I, J>, n: usize) -> bool {
        return Drive<I>::limit(&it->a, n)
    }
}

class <I, J> Drive<Zip<I, J>> derives ZipDrive<I, J> { }

priv class <I impl Iterator, J impl Iterator> ChainDrive requires __builtin_is_same<J::Item, I::Item>() {
    static inline fn <S impl Sink<I::Item>> run(it: *Chain<I, J>, s: *S) -> bool {
        if it->a? {
            // The block ends `a` before `b` is run.
            {
                var a = move(unwrap!(it->a))
                it->a = null
                if !Drive<I>::run<S>(&a, s) {
                    it->a = move(a)
                    return false
                }
            }
        }

        return Drive<J>::run<S>(&it->b, s)
    }

    static inline fn bound(it: *const Chain<I, J>) -> Bound {
        var y = Drive<J>::bound(&it->b)
        if !it->a? {
            return y
        }

        unsafe {
            var x = Drive<I>::bound(
                held_value(
                    &it->a as unsafe *const u8,
                    sizeof(I?),
                    sizeof(I),
                    alignof(I),
                ) as unsafe *const I as *const I,
            )
            var lo = x.lo + y.lo
            if lo < x.lo {
                return Bound { lo: x.lo, exact: false }
            }

            return Bound { lo: lo, exact: x.exact && y.exact }
        }
    }

    static inline fn limit(it: *Chain<I, J>, n: usize) -> bool {
        return false
    }
}

// COMPILER-WORKAROUND(partial-forward-decl): a partial over a class declared
// with `requires` (`Chain`) is declared ahead of that class in the emitted
// C++. A clause of its own, always true, keeps it in source order.
class <I, J> Drive<Chain<I, J>> derives ChainDrive<I, J> requires sizeof usize != 0 { }

priv class <I impl DoubleEnded, J impl DoubleEnded> ChainBackDrive requires __builtin_is_same<J::Item, I::Item>() {
    static inline fn <S impl Sink<I::Item>> run(it: *Chain<I, J>, s: *S) -> bool {
        if !DriveBack<J>::run<S>(&it->b, s) {
            return false
        }

        if it->a? {
            var a = move(unwrap!(it->a))
            it->a = null
            if !DriveBack<I>::run<S>(&a, s) {
                it->a = move(a)
                return false
            }
        }

        return true
    }

    static inline fn limit(it: *Chain<I, J>, n: usize) -> bool {
        return false
    }
}

// COMPILER-WORKAROUND(partial-forward-decl): as for `Drive<Chain<I, J>>`.
class <I, J> DriveBack<Chain<I, J>> derives ChainBackDrive<I, J> requires sizeof usize != 0 { }

/// `n` is how many more items are passed on; the run ends with the item
/// that brings it to zero, so nothing is pulled after it.
priv class <T, S impl Sink<T>> TakeSink impl Sink<T> {
    var n:       usize
    var next:    *S
    var refused: bool

    inline fn put(self, @inout x: T) -> bool {
        self.n -= 1
        if !self.next->put(&x) {
            self.refused = true
            return false
        }

        return self.n != 0
    }
}

priv class <I impl Iterator> TakeDrive {
    static inline fn <S impl Sink<I::Item>> run(it: *Take<I>, s: *S) -> bool {
        if it->n == 0 {
            return true
        }

        // A source that can end itself after `n` items leaves one loop with
        // one exit, where the counting sink adds a second.
        if Drive<I>::limit(&it->it, it->n) {
            return Drive<I>::run<S>(&it->it, s)
        }

        var ts = TakeSink<I::Item, S> { n: it->n, next: s, refused: false }
        Drive<I>::run<TakeSink<I::Item, S>>(&it->it, &ts)
        it->n = ts.n
        return !ts.refused
    }

    static inline fn bound(it: *const Take<I>) -> Bound {
        var x = Drive<I>::bound(&it->it)
        return Bound { lo: least(x.lo, it->n), exact: x.exact || x.lo >= it->n }
    }

    static inline fn limit(it: *Take<I>, n: usize) -> bool {
        it->n = least(it->n, n)
        return true
    }
}

class <I> Drive<Take<I>> derives TakeDrive<I> { }

priv class <I impl DoubleEnded> TakeBackDrive requires I impl ExactSize {
    /// The items past the cut are pulled and dropped, as `next_back` drops
    /// them, and what is left is run from the back.
    static inline fn <S impl Sink<I::Item>> run(it: *Take<I>, s: *S) -> bool {
        if it->n == 0 {
            return true
        }

        var m = it->it.remaining()
        while m > it->n {
            var dropped = it->it.next_back()
            m -= 1
        }

        if m == 0 {
            return true
        }

        // The run is counted, so it ends with the last item and the inner
        // iterator is not asked for one more.
        var ts = TakeSink<I::Item, S> { n: m, next: s, refused: false }
        DriveBack<I>::run<TakeSink<I::Item, S>>(&it->it, &ts)
        it->n = ts.n
        return !ts.refused
    }

    static inline fn limit(it: *Take<I>, n: usize) -> bool {
        return false
    }
}

class <I> DriveBack<Take<I>> derives TakeBackDrive<I> { }

/// Discards `n` items, `n` not zero, and ends the run with the last of them.
priv class <T> DiscardSink impl Sink<T> {
    var n: usize

    inline fn put(self, @inout x: T) -> bool {
        self.n -= 1
        return self.n != 0
    }
}

priv class <I impl Iterator> SkipDrive {
    /// The items to discard are a run of their own, so the run that follows
    /// carries no count.
    static inline fn <S impl Sink<I::Item>> run(it: *Skip<I>, s: *S) -> bool {
        if it->n != 0 {
            var ds = DiscardSink<I::Item> { n: it->n }
            it->n = 0
            if Drive<I>::run<DiscardSink<I::Item>>(&it->it, &ds) {
                return true
            }
        }

        return Drive<I>::run<S>(&it->it, s)
    }

    static inline fn bound(it: *const Skip<I>) -> Bound {
        var x = Drive<I>::bound(&it->it)
        return Bound { lo: if x.lo > it->n => x.lo - it->n else => 0, exact: x.exact }
    }

    static inline fn limit(it: *Skip<I>, n: usize) -> bool {
        var m = it->n + n
        if m < n {
            return false
        }

        return Drive<I>::limit(&it->it, m)
    }
}

class <I> Drive<Skip<I>> derives SkipDrive<I> { }

priv class <T, S impl Sink<T>> TakeWhileSink impl Sink<T> {
    var f:       *const (fn(*const T) -> bool)
    var next:    *S
    var refused: bool

    inline fn put(self, @inout x: T) -> bool {
        if !(*self.f)(&x) {
            return false
        }

        if !self.next->put(&x) {
            self.refused = true
            return false
        }

        return true
    }
}

priv class <I impl Iterator> TakeWhileDrive {
    static inline fn <S impl Sink<I::Item>> run(it: *TakeWhile<I>, s: *S) -> bool {
        if it->done {
            return true
        }

        var ts = TakeWhileSink<I::Item, S> { f: &it->f, next: s, refused: false }
        Drive<I>::run<TakeWhileSink<I::Item, S>>(&it->it, &ts)
        if ts.refused {
            return false
        }

        it->done = true
        return true
    }

    static inline fn bound(it: *const TakeWhile<I>) -> Bound {
        return Bound { lo: 0, exact: false }
    }

    static inline fn limit(it: *TakeWhile<I>, n: usize) -> bool {
        return false
    }
}

class <I> Drive<TakeWhile<I>> derives TakeWhileDrive<I> { }

/// Ends the run with the first item the predicate refuses, and keeps it.
priv class <T> SkipWhileSink impl Sink<T> {
    var f:     *const (fn(*const T) -> bool)
    var first: T?

    inline fn put(self, @inout x: T) -> bool {
        if (*self.f)(&x) {
            return true
        }

        self.first = move(x)
        return false
    }
}

priv class <I impl Iterator> SkipWhileDrive {
    /// The skipping is a run of its own, so the run that follows carries no
    /// test.
    static inline fn <S impl Sink<I::Item>> run(it: *SkipWhile<I>, s: *S) -> bool {
        if !it->done {
            Blocks<I>::skip(&it->it, &it->f, false)
            var ws = SkipWhileSink<I::Item> { f: &it->f, first: null }
            if Drive<I>::run<SkipWhileSink<I::Item>>(&it->it, &ws) {
                return true
            }

            it->done = true
            var v = move(unwrap!(ws.first))
            if !s->put(&v) {
                return false
            }
        }

        return Drive<I>::run<S>(&it->it, s)
    }

    static inline fn bound(it: *const SkipWhile<I>) -> Bound {
        return Bound { lo: 0, exact: false }
    }

    static inline fn limit(it: *SkipWhile<I>, n: usize) -> bool {
        return false
    }
}

class <I> Drive<SkipWhile<I>> derives SkipWhileDrive<I> { }

/// `k` is how many items are discarded before the next one passed on.
priv class <T, S impl Sink<T>> StepBySink impl Sink<T> {
    var k:    usize
    var step: usize
    var next: *S

    inline fn put(self, @inout x: T) -> bool {
        if self.k != 0 {
            self.k -= 1
            return true
        }

        self.k = self.step - 1
        return self.next->put(&x)
    }
}

priv class <I impl Iterator> StepByDrive {
    static inline fn <S impl Sink<I::Item>> run(it: *StepBy<I>, s: *S) -> bool {
        var k = if it->first => 0 as usize else => it->step - 1
        it->first = false
        var ss = StepBySink<I::Item, S> { k: k, step: it->step, next: s }
        return Drive<I>::run<StepBySink<I::Item, S>>(&it->it, &ss)
    }

    static inline fn bound(it: *const StepBy<I>) -> Bound {
        var x = Drive<I>::bound(&it->it)
        var n = x.lo / it->step
        if it->first && x.lo % it->step != 0 {
            n += 1
        }

        return Bound { lo: n, exact: x.exact }
    }

    static inline fn limit(it: *StepBy<I>, n: usize) -> bool {
        return false
    }
}

class <I> Drive<StepBy<I>> derives StepByDrive<I> { }

@no_warn(S055W)
priv class <I impl Iterator> PeekableDrive {
    static inline fn <S impl Sink<I::Item>> run(it: *Peekable<I>, s: *S) -> bool {
        if it->peeked? {
            if !unwrap!(it->peeked)? {
                return true
            }

            var v: I::Item? = move(unwrap!(it->peeked))
            it->peeked = null
            var w = move(unwrap!(v))
            if !s->put(&w) {
                return false
            }
        }

        return Drive<I>::run<S>(&it->it, s)
    }

    static inline fn bound(it: *const Peekable<I>) -> Bound {
        if it->peeked? {
            return Bound { lo: 0, exact: false }
        }

        return Drive<I>::bound(&it->it)
    }

    static inline fn limit(it: *Peekable<I>, n: usize) -> bool {
        return false
    }
}

class <I> Drive<Peekable<I>> derives PeekableDrive<I> { }

priv class <I impl DoubleEnded> RevDrive {
    static inline fn <S impl Sink<I::Item>> run(it: *Rev<I>, s: *S) -> bool {
        return DriveBack<I>::run<S>(&it->it, s)
    }

    static inline fn bound(it: *const Rev<I>) -> Bound {
        return Drive<I>::bound(&it->it)
    }

    static inline fn limit(it: *Rev<I>, n: usize) -> bool {
        return DriveBack<I>::limit(&it->it, n)
    }
}

class <I> Drive<Rev<I>> derives RevDrive<I> { }

priv class <I impl DoubleEnded> RevBackDrive {
    static inline fn <S impl Sink<I::Item>> run(it: *Rev<I>, s: *S) -> bool {
        return Drive<I>::run<S>(&it->it, s)
    }

    static inline fn limit(it: *Rev<I>, n: usize) -> bool {
        return Drive<I>::limit(&it->it, n)
    }
}

class <I> DriveBack<Rev<I>> derives RevBackDrive<I> { }

priv class <U impl Copyable, S impl Sink<U>> CopiedSink impl Sink<*const U> {
    var next: *S

    inline fn put(self, @inout p: *const U) -> bool {
        eval if __builtin_is_integral<U>() {
            var x: U = *p
            return self.next->put(&x)
        } else {
            var x = (*p).copy()
            return self.next->put(&x)
        }
    }
}

priv class <I impl Iterator> CopiedDrive requires I impl PointerItems && I::Target impl Copyable && __builtin_is_same<I::Item, *const I::Target>() {
    static inline fn <S impl Sink<I::Target>> run(it: *Copied<I>, s: *S) -> bool {
        var cs = CopiedSink<I::Target, S> { next: s }
        return Drive<I>::run<CopiedSink<I::Target, S>>(&it->it, &cs)
    }

    static inline fn bound(it: *const Copied<I>) -> Bound {
        return Drive<I>::bound(&it->it)
    }

    static inline fn limit(it: *Copied<I>, n: usize) -> bool {
        return Drive<I>::limit(&it->it, n)
    }
}

// COMPILER-WORKAROUND(partial-forward-decl): as for `Drive<Chain<I, J>>`.
class <I> Drive<Copied<I>> derives CopiedDrive<I> requires sizeof usize != 0 { }

priv class <I impl DoubleEnded> CopiedBackDrive requires I impl PointerItems && I::Target impl Copyable && __builtin_is_same<I::Item, *const I::Target>() {
    static inline fn <S impl Sink<I::Target>> run(it: *Copied<I>, s: *S) -> bool {
        var cs = CopiedSink<I::Target, S> { next: s }
        return DriveBack<I>::run<CopiedSink<I::Target, S>>(&it->it, &cs)
    }

    static inline fn limit(it: *Copied<I>, n: usize) -> bool {
        return DriveBack<I>::limit(&it->it, n)
    }
}

// COMPILER-WORKAROUND(partial-forward-decl): as for `Drive<Chain<I, J>>`.
class <I> DriveBack<Copied<I>> derives CopiedBackDrive<I> requires sizeof usize != 0 { }

// --- consumers --------------------------------------------------------------

priv class <A, T> FoldSink impl Sink<T> {
    var acc: A
    var f:   *const (fn(A, T) -> A)

    inline fn put(self, @inout x: T) -> bool {
        self.acc = (*self.f)(move(self.acc), move(x))
        return true
    }
}

priv class <T> CountSink impl Sink<T> {
    var n: usize

    inline fn put(self, @inout x: T) -> bool {
        self.n += 1
        return true
    }
}

priv class <T> LastSink impl Sink<T> {
    var best: T?

    inline fn put(self, @inout x: T) -> bool {
        self.best = move(x)
        return true
    }
}

priv class <T> NthSink impl Sink<T> {
    var k:   usize
    var out: T?

    inline fn put(self, @inout x: T) -> bool {
        if self.k == 0 {
            self.out = move(x)
            return false
        }

        self.k -= 1
        return true
    }
}

priv class <T> FindSink impl Sink<T> {
    var f:   *const (fn(*const T) -> bool)
    var out: T?

    inline fn put(self, @inout x: T) -> bool {
        if (*self.f)(&x) {
            self.out = move(x)
            return false
        }

        return true
    }
}

/// `i` counts the items the predicate refused; `hit` is set by the first it
/// holds for (`position`, `any`).
priv class <T> TestSink impl Sink<T> {
    var f:   *const (fn(*const T) -> bool)
    var i:   usize
    var hit: bool

    inline fn put(self, @inout x: T) -> bool {
        if (*self.f)(&x) {
            self.hit = true
            return false
        }

        self.i += 1
        return true
    }
}

/// `ok` is cleared by the first item the predicate refuses (`all`).
priv class <T> AllSink impl Sink<T> {
    var f:  *const (fn(*const T) -> bool)
    var ok: bool

    inline fn put(self, @inout x: T) -> bool {
        if !(*self.f)(&x) {
            self.ok = false
            return false
        }

        return true
    }
}

priv class <T> EachSink impl Sink<T> {
    var f: *const (fn(T))

    inline fn put(self, @inout x: T) -> bool {
        (*self.f)(move(x))
        return true
    }
}

priv class <T> PartitionSink impl Sink<T> {
    var f:   *const (fn(*const T) -> bool)
    var yes: [T]
    var no:  [T]

    inline fn put(self, @inout x: T) -> bool {
        if (*self.f)(&x) {
            self.yes.push(move(x))
        } else {
            self.no.push(move(x))
        }

        return true
    }
}

priv class <T, K impl Hash> GroupSink impl Sink<T> {
    var key: *const (fn(*const T) -> K)
    var m:   {K: [T]}

    inline fn put(self, @inout x: T) -> bool {
        var k = (*self.key)(&x)
        var empty: [T]
        self.m.get_or_insert(move(k), move(empty))->push(move(x))
        return true
    }
}

/// A vector whose raw slots are written directly. Deriving `Vector` is what
/// reaches its buffer and its length from this module.
priv class <T> VectorFill derives Vector<T> {
    inline fn VectorFill(self, v: Vector<T>) {
        Vector<T>::Vector(self, move(v))
    }

    inline fn slots(self) -> unsafe *T {
        return self.base_()
    }

    /// The first `n` slots hold values.
    inline fn filled(self, n: usize) {
        self.set_len_(n)
    }

    inline fn room(const self) -> usize {
        return self.cap_()
    }

    /// Appends `*x` to a vector whose first `n` slots hold values and which
    /// has no room left: the vector grows by its own rule. Out of line, so
    /// that a loop that pushes carries one call for it.
    @cold_path @no_inline fn grow_put(self, n: usize, x: *T) {
        self.set_len_(n)
        var v: *Vector<T> = &self
        v->push(move(*x))
    }

    inline fn finish(self) -> Vector<T> {
        return Vector<T>(move(self))
    }
}

/// Writes each item into the next raw slot at `at`. There is no capacity
/// test: the run is one whose exact length the slots were allocated for.
priv class <T> FillSink impl Sink<T> {
    var at: unsafe *T
    var n:  usize

    inline fn put(self, @inout x: T) -> bool {
        unsafe {
            __builtin_construct_at<T>((self.at + self.n) as unsafe *u8, move(x))
        }

        self.n += 1
        return true
    }
}

/// Writes each item into the next raw slot while there is room, and ends
/// the run at the first item there is no room for, which it keeps. The
/// vector grows between two runs and not inside one, so the loop carries no
/// call and reads nothing from the vector.
priv class <T> RoomSink impl Sink<T> {
    var at:   unsafe *T
    var n:    usize
    var room: usize
    var over: T?

    inline fn put(self, @inout x: T) -> bool {
        @unlikely
        if self.n == self.room {
            self.over = move(x)
            return false
        }

        unsafe {
            __builtin_construct_at<T>((self.at + self.n) as unsafe *u8, move(x))
        }

        self.n += 1
        return true
    }
}

/// A vector is built in place by a run: one allocation and a store per item
/// when the chain's length is exact, and otherwise one reservation and
/// growth when that is used up.
///
/// `hint` is what the chain says of its own length, zero when it says
/// nothing. It sizes the reservation and no more: only this file's bound is
/// trusted to store without a capacity test.
priv class <I impl Iterator> CollectVector {
    static inline fn run(it: *I, hint: usize) -> Vector<I::Item> {
        var b = Drive<I>::bound(it)
        var room = if b.exact || b.lo > hint => b.lo else => hint
        var w = VectorFill<I::Item>(Vector<I::Item>::with_capacity(room))
        if b.exact {
            var fs = FillSink<I::Item> { at: w.slots(), n: 0 }
            Drive<I>::run<FillSink<I::Item>>(it, &fs)
            w.filled(fs.n)
        } else {
            var rs = RoomSink<I::Item> { at: w.slots(), n: 0, room: w.room(), over: null }
            while !Drive<I>::run<RoomSink<I::Item>>(it, &rs) {
                var x = move(unwrap!(rs.over))
                rs.over = null
                w.grow_put(rs.n, &x)
                rs.n   += 1
                rs.at   = w.slots()
                rs.room = w.room()
            }

            w.filled(rs.n)
        }

        return w.finish()
    }
}

priv inline fn <I impl Iterator, C> collect_vector(it: *I, hint: usize) -> C requires __builtin_is_same<C, Vector<I::Item>>() {
    return CollectVector<I>::run(it, hint)
}

/// Builds the target of `collect`: a vector by a run, any other target by
/// its `from_iter`, with the chain's lower bound as the hint.
///
/// COMPILER-WORKAROUND(partial-forward-decl): the vector is told apart by an
/// `eval if`. A partial over `Vector<T>` is declared ahead of `Vector` in
/// the emitted C++ of this module.
///
/// The chain comes by pointer: each move of it on the way to the loop is a
/// constructor and a destructor the loop's function has to carry.
priv inline fn <I impl Iterator, C impl FromIterator<I::Item>> collect_into(it: *I, hint: usize) -> C {
    eval if __builtin_is_same<C, Vector<I::Item>>() {
        return collect_vector<I, C>(it, hint)
    } else {
        var b = Drive<I>::bound(it)
        return C::from_iter(move(*it), if b.lo > hint => b.lo else => hint)
    }
}

extend <I impl Iterator> Iter<I> impl Iterator {
    type Item = I::Item
    inline fn next(self) -> I::Item? {
        return self.it.next()
    }
}

extend <I impl Iterator> Iter<I> {
    pub inline fn <U> map(self, f: fn(I::Item) -> U) -> Iter<Map<I, U>> {
        return Iter<Map<I, U>> { it: Map<I, U> { it: move(self.it), f: f } }
    }

    pub inline fn filter(self, f: fn(*const I::Item) -> bool) -> Iter<Filter<I>> {
        return Iter<Filter<I>> { it: Filter<I> { it: move(self.it), f: f } }
    }

    pub inline fn <U> filter_map(self, f: fn(I::Item) -> U?) -> Iter<FilterMap<I, U>> {
        return Iter<FilterMap<I, U>> { it: FilterMap<I, U> { it: move(self.it), f: f } }
    }

    pub inline fn <J impl Iterator> flat_map(self, f: fn(I::Item) -> J) -> Iter<FlatMap<I, J>> {
        return Iter<FlatMap<I, J>> { it: FlatMap<I, J> { it: move(self.it), f: f, cur: null } }
    }

    pub inline fn enumerate(self) -> Iter<Enumerate<I>> {
        return Iter<Enumerate<I>> { it: Enumerate<I> { it: move(self.it), i: 0 } }
    }

    pub inline fn <J impl Iterator> zip(self, other: J) -> Iter<Zip<I, J>> {
        return Iter<Zip<I, J>> { it: Zip<I, J> { a: move(self.it), b: move(other) } }
    }

    pub inline fn <J impl Iterator> chain(self, other: J) -> Iter<Chain<I, J>> requires __builtin_is_same<J::Item, I::Item>() {
        return Iter<Chain<I, J>> { it: Chain<I, J> { a: move(self.it), b: move(other) } }
    }

    pub inline fn take(self, n: usize) -> Iter<Take<I>> {
        return Iter<Take<I>> { it: Take<I> { it: move(self.it), n: n } }
    }

    pub inline fn skip(self, n: usize) -> Iter<Skip<I>> {
        return Iter<Skip<I>> { it: Skip<I> { it: move(self.it), n: n } }
    }

    pub inline fn take_while(self, f: fn(*const I::Item) -> bool) -> Iter<TakeWhile<I>> {
        return Iter<TakeWhile<I>> { it: TakeWhile<I> { it: move(self.it), f: f, done: false } }
    }

    pub inline fn skip_while(self, f: fn(*const I::Item) -> bool) -> Iter<SkipWhile<I>> {
        return Iter<SkipWhile<I>> { it: SkipWhile<I> { it: move(self.it), f: f, done: false } }
    }

    /// Traps when `n` is zero.
    pub inline fn step_by(self, n: usize) -> Iter<StepBy<I>> {
        if n == 0 {
            __builtin_trap()
        }

        return Iter<StepBy<I>> { it: StepBy<I> { it: move(self.it), step: n, first: true } }
    }

    pub inline fn peekable(self) -> Iter<Peekable<I>> {
        return Iter<Peekable<I>> { it: Peekable<I> { it: move(self.it), peeked: null } }
    }

    /// The target's `from_iter` gets the chain with a lower bound on its
    /// length as the hint. A vector is built here instead, with one
    /// allocation and no capacity test when the chain's length is exact (a
    /// slice source under adapters that keep or cut the length).
    ///
    /// COMPILER-WORKAROUND(overload-across-extends): the clause keeps this
    /// one off a chain that has the sized `collect`. A generic member
    /// declared in two extensions under different bounds is ambiguous at
    /// the call, where a member with no parameter of its own is not.
    pub inline fn <C impl FromIterator<I::Item>> collect(self) -> C requires !(I impl ExactSize) {
        return collect_into<I, C>(&self.it, 0)
    }

    pub inline fn <A> fold(self, init: A, f: fn(A, I::Item) -> A) -> A {
        var s = FoldSink<A, I::Item> { acc: move(init), f: &f }
        Drive<I>::run<FoldSink<A, I::Item>>(&self.it, &s)
        return move(s.acc)
    }

    /// Null when there is no item; the one item when there is one.
    pub inline fn reduce(self, f: fn(I::Item, I::Item) -> I::Item) -> I::Item? {
        var first = self.it.next()
        if !first? {
            return null
        }

        var s = FoldSink<I::Item, I::Item> { acc: move(unwrap!(first)), f: &f }
        Drive<I>::run<FoldSink<I::Item, I::Item>>(&self.it, &s)
        return move(s.acc)
    }

    /// Runs the whole chain: an adapter's callback may be observed, so the
    /// count is never read from a length.
    pub inline fn count(self) -> usize {
        var s = CountSink<I::Item> { n: Blocks<I>::count(&self.it) }
        Drive<I>::run<CountSink<I::Item>>(&self.it, &s)
        return s.n
    }

    pub inline fn last(self) -> I::Item? {
        var s = LastSink<I::Item> { best: null }
        Drive<I>::run<LastSink<I::Item>>(&self.it, &s)
        return move(s.best)
    }

    /// Item `n`, counting from zero; the items before it are dropped.
    pub inline fn nth(self, n: usize) -> I::Item? {
        var s = NthSink<I::Item> { k: n, out: null }
        Drive<I>::run<NthSink<I::Item>>(&self.it, &s)
        return move(s.out)
    }

    pub inline fn find(self, f: fn(*const I::Item) -> bool) -> I::Item? {
        Blocks<I>::skip(&self.it, &f, true)
        var s = FindSink<I::Item> { f: &f, out: null }
        Drive<I>::run<FindSink<I::Item>>(&self.it, &s)
        return move(s.out)
    }

    pub inline fn position(self, f: fn(*const I::Item) -> bool) -> usize? {
        var s = TestSink<I::Item> { f: &f, i: Blocks<I>::skip(&self.it, &f, true), hit: false }
        Drive<I>::run<TestSink<I::Item>>(&self.it, &s)
        if s.hit {
            return s.i
        }

        return null
    }

    pub inline fn any(self, f: fn(*const I::Item) -> bool) -> bool {
        Blocks<I>::skip(&self.it, &f, true)
        var s = TestSink<I::Item> { f: &f, i: 0, hit: false }
        Drive<I>::run<TestSink<I::Item>>(&self.it, &s)
        return s.hit
    }

    pub inline fn all(self, f: fn(*const I::Item) -> bool) -> bool {
        Blocks<I>::skip(&self.it, &f, false)
        var s = AllSink<I::Item> { f: &f, ok: true }
        Drive<I>::run<AllSink<I::Item>>(&self.it, &s)
        return s.ok
    }

    pub inline fn for_each(self, f: fn(I::Item)) {
        var s = EachSink<I::Item> { f: &f }
        Drive<I>::run<EachSink<I::Item>>(&self.it, &s)
    }

    /// The items the predicate holds for, then the others, each in order.
    pub fn partition(self, f: fn(*const I::Item) -> bool) -> ([I::Item], [I::Item]) {
        var yes: [I::Item]
        var no:  [I::Item]
        var s = PartitionSink<I::Item> { f: &f, yes: move(yes), no: move(no) }
        Drive<I>::run<PartitionSink<I::Item>>(&self.it, &s)
        return (move(s.yes), move(s.no))
    }

    /// Keys in order of first appearance; each group in the order pulled.
    pub fn <K impl Hash> group_by(self, key: fn(*const I::Item) -> K) -> {K: [I::Item]} {
        var m: {K: [I::Item]}
        var s = GroupSink<I::Item, K> { key: &key, m: move(m) }
        Drive<I>::run<GroupSink<I::Item, K>>(&self.it, &s)
        return move(s.m)
    }
}

extend <I impl ExactSize> Iter<I> impl ExactSize {
    inline fn remaining(const self) -> usize {
        return self.it.remaining()
    }
}

/// Chosen over the plain `collect` when the length is known: the target is
/// sized once, by `remaining()`.
extend <I impl ExactSize> Iter<I> {
    pub inline fn <C impl FromIterator<I::Item>> collect(self) -> C {
        var n = self.it.remaining()
        return collect_into<I, C>(&self.it, n)
    }
}

extend <I impl DoubleEnded> Iter<I> {
    pub inline fn rev(self) -> Iter<Rev<I>> {
        return Iter<Rev<I>> { it: Rev<I> { it: move(self.it) } }
    }
}

/// `peekable()` returns the wrapper, which is where a chain's members are
/// found: without this one `Peekable::peek` has no caller.
extend <I impl Iterator> Iter<Peekable<I>> {
    pub inline fn peek(self) -> (*const I::Item)? {
        return self.it.peek()
    }
}

/// A chain reads from its back where its iterator does.
extend <I impl DoubleEnded> Iter<I> impl DoubleEnded {
    inline fn next_back(self) -> I::Item? {
        return self.it.next_back()
    }
}

/// The items a generator of pointers points at, copied.
extend <U impl Copyable> Iter<Yield<*const U>> {
    pub inline fn copied(self) -> Iter<Copied<Pointed<U>>> {
        return Iter<Copied<Pointed<U>>> { it: Copied<Pointed<U>> { it: Pointed<U> { it: move(self.it) } } }
    }
}

/// Container iteration yields pointers; this yields the elements.
extend <I impl Iterator> Iter<I> requires I impl PointerItems && I::Target impl Copyable && __builtin_is_same<I::Item, *const I::Target>() {
    pub inline fn copied(self) -> Iter<Copied<I>> {
        return Iter<Copied<I>> { it: Copied<I> { it: move(self.it) } }
    }
}

priv class <T impl Ord> MinSink impl Sink<T> {
    var best: T

    inline fn put(self, @inout x: T) -> bool {
        if (x <=> self.best) == Ordering::Less {
            self.best = move(x)
        }

        return true
    }
}

priv class <T impl Ord> MaxSink impl Sink<T> {
    var best: T

    inline fn put(self, @inout x: T) -> bool {
        if (x <=> self.best) != Ordering::Less {
            self.best = move(x)
        }

        return true
    }
}

extend <I impl Iterator> Iter<I> requires I::Item impl Ord {
    /// The first of several equal smallest items.
    pub inline fn min(self) -> I::Item? {
        var first = self.it.next()
        if !first? {
            return null
        }

        var s = MinSink<I::Item> { best: move(unwrap!(first)) }
        Drive<I>::run<MinSink<I::Item>>(&self.it, &s)
        return move(s.best)
    }

    /// The last of several equal largest items.
    pub inline fn max(self) -> I::Item? {
        var first = self.it.next()
        if !first? {
            return null
        }

        var s = MaxSink<I::Item> { best: move(unwrap!(first)) }
        Drive<I>::run<MaxSink<I::Item>>(&self.it, &s)
        return move(s.best)
    }

    /// Stable: equal items keep the order they were pulled in.
    pub fn sorted(self) -> [I::Item] {
        var v: [I::Item] = CollectVector<I>::run(&self.it, 0)
        v.sort()
        return move(v)
    }
}

priv class <T impl Hash> CountsSink impl Sink<T> {
    var m: {T: usize}

    inline fn put(self, @inout x: T) -> bool {
        *self.m.get_or_insert(move(x), 0) += 1
        return true
    }
}

extend <I impl Iterator> Iter<I> requires I::Item impl Hash {
    /// How many times each item appears, keyed in order of first appearance.
    pub fn counts(self) -> {I::Item: usize} {
        var m: {I::Item: usize}
        var s = CountsSink<I::Item> { m: move(m) }
        Drive<I>::run<CountsSink<I::Item>>(&self.it, &s)
        return move(s.m)
    }
}

/// COMPILER-WORKAROUND(witness-unused-bound): `I::Item::make_default()`
/// under `requires I::Item impl Default` reaches no witness when the item
/// is a primitive, so the identity comes through a function whose own
/// parameter carries the bound.
priv inline fn <T impl Default> default_of() -> T {
    return T::make_default()
}

priv class <T impl Add> SumSink impl Sink<T> {
    var acc: T

    inline fn put(self, @inout x: T) -> bool {
        self.acc = self.acc + x
        return true
    }
}

extend <I impl Iterator> Iter<I> requires I::Item impl Add && I::Item impl Default {
    /// `make_default()` when there is no item.
    pub inline fn sum(self) -> I::Item {
        var s = SumSink<I::Item> { acc: default_of<I::Item>() }
        Drive<I>::run<SumSink<I::Item>>(&self.it, &s)
        return move(s.acc)
    }
}

priv class <T impl Append> JoinSink impl Sink<T> {
    var out:   string
    var sep:   *const string
    var first: bool

    inline fn put(self, @inout x: T) -> bool {
        if !self.first {
            self.out.push_str(*self.sep)
        }

        self.first = false
        x.append_to(&self.out)
        return true
    }
}

extend <I impl Iterator> Iter<I> requires I::Item impl Append {
    pub fn join(self, const sep: string = "") -> string {    // one buffer for the whole result
        var out: string
        var s = JoinSink<I::Item> { out: move(out), sep: &sep, first: true }
        Drive<I>::run<JoinSink<I::Item>>(&self.it, &s)
        return move(s.out)
    }
}
