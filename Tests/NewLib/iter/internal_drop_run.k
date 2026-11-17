// A consumer leaves nothing behind: every item a chain builds is destroyed,
// whether the consumer took it, an adapter discarded it, or the run ended
// before it was reached, and so is every iterator. `Tracked` is a move-only
// item that counts its live objects; `Owner` is a move-only iterator that
// counts its own. Each consumer runs over each chain, with a predicate that
// stops it early and one that never does.

import std::iter::*
import std::io

var live: i64 = 0
var built: i64 = 0
var owners: i64 = 0
var failed: i32 = 0
var seen: i64 = 0

class Tracked {
    pub var v: i64

    pub fn Tracked(self, v: i64) {
        self.v = v
        live  += 1
        built += 1
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

/// A generator that holds a live item of its own across each yield.
fn tracked_gen(n: i64) -> yield Tracked {
    var kept = Tracked(100)
    for var i: i64 = 0; i < n; i += 1 {
        yield Tracked(i + kept.v - 100)
    }
}

fn clean(const label: string, const what: string) {
    if live != 0 || owners != 0 {
        failed += 1
        io::println(f"FAILED {label}, {what}: {live} items and {owners} iterators left")
    }

    live   = 0
    owners = 0
}

fn hold(const label: string, const what: string, cond: bool) {
    if !cond {
        failed += 1
        io::println(f"FAILED {label}, {what}")
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
fn no_item(x: *const Tracked) -> bool = false
fn is_even(x: *const Tracked) -> bool = (x->v & 1) == 0
fn is_three(x: *const Tracked) -> bool = x->v == 3
fn below_four(x: *const Tracked) -> bool = x->v < 4
fn owner_to(x: Tracked) -> Owner = Owner(x.v % 3 + 1)
fn second(e: (usize, Tracked)) -> Tracked = move(e.1)
fn left(e: (Tracked, Tracked)) -> Tracked = move(e.0)
fn keep_odd(x: Tracked) -> Tracked? {
    if (x.v & 1) == 1 {
        return move(x)
    }

    return null
}
fn later(a: Tracked, b: Tracked) -> Tracked = move(b)
fn count_up(acc: i64, x: Tracked) -> i64 = acc + 1
fn see(x: Tracked) {
    seen += 1
}
fn parity(x: *const Tracked) -> i64 = x->v & 1

/// Every consumer over a fresh build of `chain`. `total` is how many items
/// the whole chain yields. What a consumer returns is alive until its block
/// ends, and so is what a generator stopped early still holds.
macro drops!(label, total, chain) {
    {
        {
            var c = chain
            hold(label, "count", c.count() as i64 == total)
        }
        clean(label, "count")
        {
            var c = chain
            hold(label, "fold", c.fold<i64>(0, count_up) == total)
        }
        clean(label, "fold")
        {
            var c = chain
            var x? = c.reduce(later)
            hold(label, "reduce", x? == (total != 0))
        }
        clean(label, "reduce")
        {
            var c = chain
            var x? = c.last()
            hold(label, "last", x? == (total != 0))
        }
        clean(label, "last")
        {
            var c = chain
            var x? = c.nth(2)
            hold(label, "nth", x? == (total > 2))
        }
        clean(label, "nth")
        {
            var c = chain
            var x? = c.nth(1000)
            hold(label, "nth past the end", !x?)
        }
        clean(label, "nth past the end")
        {
            var c = chain
            var x? = c.find(any_item)
            hold(label, "find first", x? == (total != 0))
        }
        clean(label, "find first")
        {
            var c = chain
            var x? = c.find(no_item)
            hold(label, "find none", !x?)
        }
        clean(label, "find none")
        {
            var c = chain
            var i? = c.position(is_three)
            var j? = move(i)
        }
        clean(label, "position")
        {
            var c = chain
            hold(label, "any", c.any(any_item) == (total != 0))
        }
        clean(label, "any")
        {
            var c = chain
            hold(label, "all", c.all(no_item) == (total == 0))
        }
        clean(label, "all")
        {
            var c = chain
            seen = 0
            c.for_each(see)
            hold(label, "for_each", seen == total)
        }
        clean(label, "for_each")
        {
            var c = chain
            var v = c.collect<[Tracked]>()
            hold(label, "collect", v.size() as i64 == total && live >= total)
        }
        clean(label, "collect")
        {
            var c = chain
            var parts = c.partition(is_even)
            hold(label, "partition", (parts.0.size() + parts.1.size()) as i64 == total && live >= total)
        }
        clean(label, "partition")
        {
            var c = chain
            var groups = c.group_by<i64>(parity)
            hold(label, "group_by", live >= total)
        }
        clean(label, "group_by")
        {
            // One item pulled by hand, then the rest taken by a consumer.
            var c = chain
            var x? = c.next()
            var n = c.count() as i64
            hold(label, "next then count", n == (if total == 0 => 0 else => total - 1))
        }
        clean(label, "next then count")
    }
}

fn main() -> i32 {
    drops!("source", 6, iter(Owner(6)))
    drops!("empty source", 0, iter(Owner(0)))
    drops!("generator", 6, iter(tracked_gen(6)))
    drops!("map", 6, iter(Owner(6)).map<Tracked>(same))
    drops!("filter", 3, iter(Owner(6)).filter(is_even))
    drops!("filter_map", 3, iter(Owner(6)).filter_map<Tracked>(keep_odd))
    drops!("flat_map", 7, iter(Owner(4)).flat_map<Owner>(owner_to))
    drops!("enumerate", 6, iter(Owner(6)).enumerate().map<Tracked>(second))
    drops!("zip", 4, iter(Owner(6)).zip(Owner(4)).map<Tracked>(left))
    drops!("zip, short first", 3, iter(Owner(3)).zip(Owner(5)).map<Tracked>(left))
    drops!("chain", 9, iter(Owner(6)).chain(Owner(3)))
    drops!("take", 4, iter(Owner(6)).take(4))
    drops!("skip", 4, iter(Owner(6)).skip(2))
    drops!("skip past the end", 0, iter(Owner(6)).skip(9))
    drops!("take_while", 4, iter(Owner(6)).take_while(below_four))
    drops!("skip_while", 2, iter(Owner(6)).skip_while(below_four))
    drops!("step_by", 3, iter(Owner(7)).step_by(3))
    drops!("peekable", 6, iter(Owner(6)).peekable())
    drops!("take.chain", 5, iter(Owner(6)).take(2).chain(Owner(3)))
    drops!("take_while.chain", 7, iter(Owner(6)).take_while(below_four).chain(Owner(3)))
    drops!("flat_map.skip.take", 4, iter(Owner(4)).flat_map<Owner>(owner_to).skip(3).take(4))
    drops!("chain.skip_while.step_by", 3, iter(Owner(6)).chain(Owner(3)).skip_while(below_four).step_by(2))
    drops!("generator chain", 2, iter(tracked_gen(8)).filter(is_even).skip(1).take(2))

    // Every item built above was destroyed, and none twice.
    hold("total", "balance", live == 0 && built > 0)
    return if failed == 0 => 0 else => 1
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo_new -O2 %s -o %t.O2.exe --cache-dir %t.d
// RUN: %t.O2.exe
