// An ambiguous partial selection is reported once per build, whichever TU
// names the instance first.
//
// The eight user files import pair.k and not each other, so their T fronts
// run side by side on the pool, and each meets the one build-wide entry for
// Pair<i32, i32> with its ambiguity unreported. The "reported" latch is not a
// plain check-then-set (two fronts could both see it clear and both
// report SC157E): InstantiationRegistry::claim takes it under
// the registry lock, so exactly one front wins and reports. Which file
// that is follows pool arrival order, so the check names none.

import self::user0::*
import self::user1::*
import self::user2::*
import self::user3::*
import self::user4::*
import self::user5::*
import self::user6::*
import self::user7::*

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --threads=8 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: user{{[0-7]}}.k:5:12: error [SC157E]: ambiguous partial specializations of 'Pair' for these arguments
