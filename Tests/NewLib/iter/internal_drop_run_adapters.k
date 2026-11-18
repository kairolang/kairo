// A consumer leaves nothing behind: every item a chain builds is destroyed,
// whether the consumer took it, an adapter discarded it, or the run ended
// before it was reached, and so is every iterator. `Tracked` is a move-only
// item that counts its live objects; `Owner` is a move-only iterator that
// counts its own. Each consumer runs over each chain, with a predicate that
// stops it early and one that never does.

import std::iter::*
import std::io
import self::Inputs::internal_drop::*

fn main() -> i32 {
    drops!("source", 6, iter(Owner(6)))
    drops!("empty source", 0, iter(Owner(0)))
    drops!("generator", 6, iter(tracked_gen(6)))
    drops!("map", 6, iter(Owner(6)).map<Tracked>(same))
    drops!("filter", 3, iter(Owner(6)).filter(is_even))
    drops!("filter_map", 3, iter(Owner(6)).filter_map<Tracked>(keep_odd))
    drops!("flat_map", 7, iter(Owner(4)).flat_map<Owner>(owner_to))
    drops!("enumerate", 6, iter(Owner(6)).enumerate().map<Tracked>(second))

    // Every item built above was destroyed, and none twice.
    hold("total", "balance", live == 0 && built > 0)
    return if failed == 0 => 0 else => 1
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
