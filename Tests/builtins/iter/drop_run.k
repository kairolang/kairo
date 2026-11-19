// A chain dropped part-way destroys everything it holds: the items it
// buffers (a peeked item, the sub-iterator of a flat_map), the items its
// source has not yielded, and the iterators themselves. `Tracked` is a
// move-only item that counts its live objects; `Owner` is a move-only
// iterator that counts its own. Chain and FlatMap destroy an inner
// iterator when it ends, not when the chain does.

import std::iter::*
import std::io

var live: i64 = 0
var owners: i64 = 0
var failed: i32 = 0

class Tracked {
    pub var v: i64

    pub fn Tracked(self, v: i64) {
        self.v = v
        live += 1
    }

    @move pub fn Tracked(self, other: Self) {
        self.v  = other.v
        other.v = -1
        live += 1
    }

    pub fn op finally(self) {
        live -= 1
    }
}

/// Yields Tracked(0) ... Tracked(n - 1), each built when it is pulled.
class Owner {
    var at:  i64
    var end: i64

    pub fn Owner(self, n: i64) {
        self.at  = 0
        self.end = n
        owners += 1
    }

    @move pub fn Owner(self, other: Self) {
        self.at   = other.at
        self.end  = other.end
        other.end = other.at
        owners += 1
    }

    pub fn op finally(self) {
        owners -= 1
    }
}

extend Owner impl Iterator {
    type Item = Tracked
    fn next(self) -> Tracked? {
        if self.at == self.end {
            return null
        }

        self.at += 1
        return Tracked(self.at - 1)
    }
}

/// A generator that holds live items of its own across each yield.
fn tracked_gen(n: i64) -> yield Tracked {
    var kept = Tracked(100)
    for var i: i64 = 0; i < n; i += 1 {
        yield Tracked(i + kept.v - 100)
    }
}

fn clean(const label: string) {
    if live != 0 || owners != 0 {
        failed += 1
        io::println(f"FAILED {label}: {live} items and {owners} iterators left")
    }

    live   = 0
    owners = 0
}

fn hold(const label: string, cond: bool) {
    if !cond {
        failed += 1
        io::println(f"FAILED {label}")
    }
}

/// The item's value, or -1 for null.
fn val(x: Tracked?) -> i64 {
    if x? {
        return x.v
    }

    return -1
}

fn same(x: Tracked) -> Tracked = x
fn any_item(x: *const Tracked) -> bool = true
fn is_even(x: *const Tracked) -> bool = (x->v & 1) == 0
fn below_two(x: *const Tracked) -> bool = x->v < 2
fn owner_to(x: Tracked) -> Owner = Owner(x.v + 2)
fn keep_odd(x: Tracked) -> Tracked? {
    if (x.v & 1) == 1 {
        return move(x)
    }

    return null
}

fn one_pull_then_drop() {
    {
        var c = iter(Owner(5)).map<Tracked>(same)
        hold("map pull", val(c.next()) == 0)
    }
    clean("map")
    {
        var c = iter(Owner(5)).filter(is_even)
        hold("filter pull", val(c.next()) == 0)
        hold("filter pull 2", val(c.next()) == 2)
    }
    clean("filter")
    {
        var c = iter(Owner(5)).filter_map<Tracked>(keep_odd)
        hold("filter_map pull", val(c.next()) == 1)
    }
    clean("filter_map")
    {
        var c = iter(Owner(5)).enumerate()
        var x? = c.next()
        hold("enumerate pull", x?)
    }
    clean("enumerate")
    {
        var c = iter(Owner(5)).zip(Owner(3))
        var x? = c.next()
        hold("zip pull", x?)
    }
    clean("zip")
    {
        var c = iter(Owner(3)).zip(Owner(1))
        var x? = c.next()
        var y? = c.next()
        hold("zip drops the item pulled from a when b has ended", x? && !y?)
    }
    clean("zip uneven")
    {
        var c = iter(Owner(5)).take(3)
        hold("take pull", val(c.next()) == 0)
    }
    clean("take")
    {
        var c = iter(Owner(5)).skip(2)
        hold("skip pull", val(c.next()) == 2)
    }
    clean("skip")
    {
        var c = iter(Owner(5)).take_while(below_two)
        hold("take_while pull", val(c.next()) == 0)
    }
    clean("take_while")
    {
        var c = iter(Owner(5)).take_while(below_two)
        hold("take_while drains", c.count() == 2)
    }
    clean("take_while refused item")
    {
        var c = iter(Owner(5)).skip_while(below_two)
        hold("skip_while pull", val(c.next()) == 2)
    }
    clean("skip_while")
    {
        var c = iter(Owner(7)).step_by(3)
        hold("step_by pull", val(c.next()) == 0)
        hold("step_by pull 2", val(c.next()) == 3)
    }
    clean("step_by")
}

fn buffered_items() {
    {
        var c = iter(Owner(5)).peekable()
        var *p? = c.peek()
        hold("peek", p? && unwrap!(p)->v == 0)
        hold("one item is held", live == 1)
    }
    clean("peekable with a held item")
    {
        var c = iter(Owner(5)).peekable()
        var *p? = c.peek()
        hold("peek then next", val(c.next()) == 0 && val(c.next()) == 1)
        var *q? = c.peek()
        hold("peek again", q? && unwrap!(q)->v == 2)
    }
    clean("peekable after peek, next, peek")
    {
        var c = iter(Owner(1)).peekable()
        hold("peek to the end", val(c.next()) == 0 && !c.peek()? && !c.next()?)
    }
    clean("peekable at its end")
    {
        var c = iter(Owner(3)).flat_map<Owner>(owner_to)
        hold("flat_map pull", val(c.next()) == 0)
        hold("flat_map holds its sub-iterator", owners == 2)
    }
    clean("flat_map with a live sub-iterator")
}

fn inner_iterators_end_early() {
    {
        var c = iter(Owner(1)).chain(Owner(2))
        hold("chain holds both", owners == 2)
        hold("chain a", val(c.next()) == 0)
        hold("chain b", val(c.next()) == 0)
        hold("chain destroyed a when it ended", owners == 1)
        hold("nothing live but the chain", live == 0)
    }
    clean("chain")
    {
        var c = iter(Owner(2)).flat_map<Owner>(owner_to)
        hold("flat_map 0", val(c.next()) == 0 && val(c.next()) == 1)
        hold("flat_map holds outer and one sub-iterator", owners == 2)
        hold("flat_map 1", val(c.next()) == 0)
        hold("flat_map replaced the ended sub-iterator", owners == 2)
        hold("flat_map 1 rest", val(c.next()) == 1 && val(c.next()) == 2 && !c.next()?)
        hold("flat_map destroyed the last sub-iterator at its end", owners == 1)
    }
    clean("flat_map")
}

fn generators() {
    {
        var c = iter(tracked_gen(5)).map<Tracked>(same).filter(any_item).take(4)
        hold("generator chain pull", val(c.next()) == 0)
        hold("generator chain pull 2", val(c.next()) == 1)
    }
    clean("generator chain dropped part-way")
    {
        var c = iter(tracked_gen(5)).peekable()
        var *p? = c.peek()
        hold("generator peek", p? && unwrap!(p)->v == 0)
    }
    clean("generator behind a peek")
    {
        var c = iter(tracked_gen(3)).chain(tracked_gen(2)).skip(1).step_by(2)
        hold("generator chain count", c.count() == 2)
    }
    clean("generator chain drained")
    {
        var c = iter(tracked_gen(3))
    }
    clean("generator never resumed")
}

fn consumers() {
    hold("find", val(iter(Owner(5)).find(is_even)) == 0)
    clean("find")
    hold("nth", val(iter(Owner(5)).nth(3)) == 3)
    clean("nth")
    hold("last", val(iter(Owner(5)).last()) == 4)
    clean("last")
    hold("position", (iter(Owner(5)).position(is_even) ?? 9) == 0)
    clean("position")
    hold("any all", iter(Owner(5)).any(is_even) && !iter(Owner(5)).all(is_even))
    clean("any / all")
    hold("count", iter(Owner(5)).count() == 5)
    clean("count")
    {
        var v = iter(Owner(5)).collect<[Tracked]>()
        hold("collect", v.size() == 5 && live == 5 && v[4].v == 4)
    }
    clean("collect")
    {
        var p = iter(Owner(5)).partition(is_even)
        hold("partition", p.0.size() == 3 && p.1.size() == 2 && live == 5)
    }
    clean("partition")
}

fn main() -> i32 {
    one_pull_then_drop()
    buffered_items()
    inner_iterators_end_early()
    generators()
    consumers()
    return failed
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo -O2 %s -o %t.O2.exe --cache-dir %t.d
// RUN: %t.O2.exe
