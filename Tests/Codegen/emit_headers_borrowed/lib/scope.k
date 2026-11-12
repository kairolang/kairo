import self::counter::{push, pop}

// A public template whose bodies the header carries, and they name the
// other file's `prot` helpers: lib/scope.hh reaches them only through its
// `#include` of lib/counter.hh.
pub class <T> Scope {
    var d: usize
    pub inline fn Scope(self) { self.d = push() }
    pub inline fn op finally(self) { pop(self.d) }
}
