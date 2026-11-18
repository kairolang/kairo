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
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
