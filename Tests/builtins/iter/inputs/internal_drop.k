import std::iter::*
import std::io

pub static live: i64 = 0
pub static built: i64 = 0
pub static owners: i64 = 0
pub static failed: i32 = 0
pub static seen: i64 = 0

pub class Tracked {
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
pub class Owner {
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
pub fn tracked_gen(n: i64) -> yield Tracked {
    var kept = Tracked(100)
    for var i: i64 = 0; i < n; i += 1 {
        yield Tracked(i + kept.v - 100)
    }
}

pub fn clean(const label: string, const what: string) {
    if live != 0 || owners != 0 {
        failed += 1
        io::println(f"FAILED {label}, {what}: {live} items and {owners} iterators left")
    }

    live   = 0
    owners = 0
}

pub fn hold(const label: string, const what: string, cond: bool) {
    if !cond {
        failed += 1
        io::println(f"FAILED {label}, {what}")
    }
}

/// The item's value, or -1 for null.
pub fn val(x: Tracked?) -> i64 {
    if x? {
        return x.v
    }

    return -1
}

pub fn same(x: Tracked) -> Tracked = x
pub fn any_item(x: *const Tracked) -> bool = true
pub fn no_item(x: *const Tracked) -> bool = false
pub fn is_even(x: *const Tracked) -> bool = (x->v & 1) == 0
pub fn is_three(x: *const Tracked) -> bool = x->v == 3
pub fn below_four(x: *const Tracked) -> bool = x->v < 4
pub fn owner_to(x: Tracked) -> Owner = Owner(x.v % 3 + 1)
pub fn second(e: (usize, Tracked)) -> Tracked = move(e.1)
pub fn left(e: (Tracked, Tracked)) -> Tracked = move(e.0)
pub fn keep_odd(x: Tracked) -> Tracked? {
    if (x.v & 1) == 1 {
        return move(x)
    }

    return null
}
pub fn later(a: Tracked, b: Tracked) -> Tracked = move(b)
pub fn count_up(acc: i64, x: Tracked) -> i64 = acc + 1
pub fn see(x: Tracked) {
    seen += 1
}
pub fn parity(x: *const Tracked) -> i64 = x->v & 1

/// Every consumer over a fresh build of `chain`. `total` is how many items
/// the whole chain yields. What a consumer returns is alive until its block
/// ends, and so is what a generator stopped early still holds.
pub macro drops!(label, total, chain) {
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
