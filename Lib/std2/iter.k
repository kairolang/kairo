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
/// Start from a generator: `iter(v.iter())`, `iter(s.lines())`.
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

pub class <U impl Copyable> Copied {
    priv var it: Yield<*const U>
}

extend <U impl Copyable> Copied<U> impl Iterator {
    type Item = U
    inline fn next(self) -> U? {
        var p = self.it.next()
        if !p? {
            return null
        }

        return (*unwrap!(p)).copy()
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

    /// The target is built with no size hint.
    ///
    /// COMPILER-WORKAROUND(conditional-conformance): the overload that
    /// passes `remaining()` for an `ExactSize` chain is not declared. Two
    /// extends declaring `collect` under different bounds are ambiguous at
    /// every call, and a clause that asks `I impl ExactSize` is answered
    /// true for every adapter that conforms conditionally (`Map<I, U>` over
    /// any `I`), which then fails in the emitted C++. A caller that knows
    /// the length passes it to `C::from_iter(chain, n)`.
    pub inline fn <C impl FromIterator<I::Item>> collect(self) -> C {
        return C::from_iter(move(self.it), 0)
    }

    pub inline fn <A> fold(self, init: A, f: fn(A, I::Item) -> A) -> A {
        var acc = move(init)
        loop {
            var x = self.it.next()
            if !x? {
                return move(acc)
            }

            acc = f(move(acc), move(unwrap!(x)))
        }
    }

    /// Null when there is no item; the one item when there is one.
    pub inline fn reduce(self, f: fn(I::Item, I::Item) -> I::Item) -> I::Item? {
        var first = self.it.next()
        if !first? {
            return null
        }

        var acc = move(unwrap!(first))
        loop {
            var x = self.it.next()
            if !x? {
                return move(acc)
            }

            acc = f(move(acc), move(unwrap!(x)))
        }
    }

    /// Runs the whole chain: an adapter's callback may be observed, so the
    /// count is never read from a length.
    pub inline fn count(self) -> usize {
        var n: usize = 0
        loop {
            var x = self.it.next()
            if !x? {
                return n
            }

            n += 1
        }
    }

    pub inline fn last(self) -> I::Item? {
        var best: I::Item? = null
        loop {
            var x = self.it.next()
            if !x? {
                return move(best)
            }

            best = move(x)
        }
    }

    /// Item `n`, counting from zero; the items before it are dropped.
    pub inline fn nth(self, n: usize) -> I::Item? {
        var k = n
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

    pub inline fn find(self, f: fn(*const I::Item) -> bool) -> I::Item? {
        loop {
            var x = self.it.next()
            if !x? {
                return null
            }

            var v = move(unwrap!(x))
            if f(&v) {
                return move(v)
            }
        }
    }

    pub inline fn position(self, f: fn(*const I::Item) -> bool) -> usize? {
        var i: usize = 0
        loop {
            var x = self.it.next()
            if !x? {
                return null
            }

            var v = move(unwrap!(x))
            if f(&v) {
                return i
            }

            i += 1
        }
    }

    pub inline fn any(self, f: fn(*const I::Item) -> bool) -> bool {
        loop {
            var x = self.it.next()
            if !x? {
                return false
            }

            var v = move(unwrap!(x))
            if f(&v) {
                return true
            }
        }
    }

    pub inline fn all(self, f: fn(*const I::Item) -> bool) -> bool {
        loop {
            var x = self.it.next()
            if !x? {
                return true
            }

            var v = move(unwrap!(x))
            if !f(&v) {
                return false
            }
        }
    }

    pub inline fn for_each(self, f: fn(I::Item)) {
        loop {
            var x = self.it.next()
            if !x? {
                return
            }

            f(move(unwrap!(x)))
        }
    }

    /// The items the predicate holds for, then the others, each in order.
    pub fn partition(self, f: fn(*const I::Item) -> bool) -> ([I::Item], [I::Item]) {
        var yes: [I::Item]
        var no:  [I::Item]
        loop {
            var x = self.it.next()
            if !x? {
                return (move(yes), move(no))
            }

            var v = move(unwrap!(x))
            if f(&v) {
                yes.push(move(v))
            } else {
                no.push(move(v))
            }
        }
    }

    /// Keys in order of first appearance; each group in the order pulled.
    pub fn <K impl Hash> group_by(self, key: fn(*const I::Item) -> K) -> {K: [I::Item]} {
        var m: {K: [I::Item]}
        loop {
            var x = self.it.next()
            if !x? {
                return move(m)
            }

            var v = move(unwrap!(x))
            var k = key(&v)
            var empty: [I::Item]
            m.get_or_insert(move(k), move(empty))->push(move(v))
        }
    }
}

extend <I impl ExactSize> Iter<I> impl ExactSize {
    inline fn remaining(const self) -> usize {
        return self.it.remaining()
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

/// Container iteration yields pointers; this yields the elements.
extend <U impl Copyable> Iter<Yield<*const U>> {
    pub inline fn copied(self) -> Iter<Copied<U>> {
        return Iter<Copied<U>> { it: Copied<U> { it: move(self.it) } }
    }
}

extend <I impl Iterator> Iter<I> requires I::Item impl Ord {
    /// The first of several equal smallest items.
    pub inline fn min(self) -> I::Item? {
        var first = self.it.next()
        if !first? {
            return null
        }

        var best = move(unwrap!(first))
        loop {
            var x = self.it.next()
            if !x? {
                return move(best)
            }

            var v = move(unwrap!(x))
            if (v <=> best) == Ordering::Less {
                best = move(v)
            }
        }
    }

    /// The last of several equal largest items.
    pub inline fn max(self) -> I::Item? {
        var first = self.it.next()
        if !first? {
            return null
        }

        var best = move(unwrap!(first))
        loop {
            var x = self.it.next()
            if !x? {
                return move(best)
            }

            var v = move(unwrap!(x))
            if (v <=> best) != Ordering::Less {
                best = move(v)
            }
        }
    }

    /// Stable: equal items keep the order they were pulled in.
    pub fn sorted(self) -> [I::Item] {
        var v: [I::Item] = Vector<I::Item>::from_iter(move(self.it), 0)
        v.sort()
        return move(v)
    }
}

extend <I impl Iterator> Iter<I> requires I::Item impl Hash {
    /// How many times each item appears, keyed in order of first appearance.
    pub fn counts(self) -> {I::Item: usize} {
        var m: {I::Item: usize}
        loop {
            var x = self.it.next()
            if !x? {
                return move(m)
            }

            *m.get_or_insert(move(unwrap!(x)), 0) += 1
        }
    }
}

/// COMPILER-WORKAROUND(witness-unused-bound): a bound on an associated type
/// (`requires I::Item impl Default`) brings no witness into the unit that
/// calls the member, so a member under such a bound reaches the interface
/// through one of these, whose own parameter carries the bound.
priv inline fn <T impl Default> default_of() -> T {
    return T::make_default()
}

priv inline fn <T impl Append> append_item(const x: T, @inout out: string) {
    x.append_to(&out)
}

extend <I impl Iterator> Iter<I> requires I::Item impl Add && I::Item impl Default {
    /// `make_default()` when there is no item.
    pub inline fn sum(self) -> I::Item {
        var acc = default_of<I::Item>()
        loop {
            var x = self.it.next()
            if !x? {
                return move(acc)
            }

            acc = acc + unwrap!(x)
        }
    }
}

extend <I impl Iterator> Iter<I> requires I::Item impl Append {
    pub fn join(self, const sep: string = "") -> string {    // one buffer for the whole result
        var out: string
        var first = true
        loop {
            var x = self.it.next()
            if !x? {
                return move(out)
            }

            if !first {
                out.push_str(sep)
            }

            first = false
            append_item<I::Item>(unwrap!(x), &out)
        }
    }
}
