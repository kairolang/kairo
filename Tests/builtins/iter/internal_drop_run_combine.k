// A consumer leaves nothing behind: every item a chain builds is destroyed,
// whether the consumer took it, an adapter discarded it, or the run ended
// before it was reached, and so is every iterator. `Tracked` is a move-only
// item that counts its live objects; `Owner` is a move-only iterator that
// counts its own. Each consumer runs over each chain, with a predicate that
// stops it early and one that never does.

import std::iter::*
import std::io
import self::inputs::internal_drop::*

fn main() -> i32 {
    drops!("zip", 4, iter(Owner(6)).zip(Owner(4)).map<Tracked>(left))
    drops!("zip, short first", 3, iter(Owner(3)).zip(Owner(5)).map<Tracked>(left))
    drops!("chain", 9, iter(Owner(6)).chain(Owner(3)))
    drops!("take", 4, iter(Owner(6)).take(4))
    drops!("skip", 4, iter(Owner(6)).skip(2))
    drops!("skip past the end", 0, iter(Owner(6)).skip(9))
    drops!("take_while", 4, iter(Owner(6)).take_while(below_four))
    drops!("skip_while", 2, iter(Owner(6)).skip_while(below_four))

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
