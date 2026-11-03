// RUN: %kairo %s --type-check-only 2>&1 | %FileCheck %s --check-prefix=DIAG --allow-empty
//
// Indirection breaks every cycle: a pointer, a nullable pointer, a vector, a
// map and a set are each satisfied by a forward declaration. Nothing here is
// diagnosed, and the compile must succeed. If any of these ever starts
// erroring, the edge classification has drifted and every recursive data
// structure in the language stopped compiling. The generic counterpart
// (`Ptr<UsesPtr>`) is in type_cycle_generic.k. See type_cycle_direct.k for
// the map.

class ByPointer  { var next: *ByPointer;      }
class ByNullPtr  { var next: *ByNullPtr?;     }
class ByVector   { var kids: [ByVector];      }
class ByMap      { var kids: {i32: ByMap};    }
class BySet impl Hash {                      // a set's element is a key
    var kids: {BySet};
    pub fn hash(const self) -> usize { return 0; }
    pub fn op ==(const self, const other: BySet) -> bool { return true; }
}

fn main() -> i32 { return 0; }

// DIAG-NOT: error
