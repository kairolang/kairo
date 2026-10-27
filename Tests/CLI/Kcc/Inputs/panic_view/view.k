// view.k: panicking functions a C++ host calls (kcc_panic_cxx_view.k).
// Line and column numbers below are pinned by the test's what() checks.
ffi "c" import "stdlib.h"

pub struct ConfigError {
    var key: i32
    fn op panic (const self) -> string { return "missing config key" }
}
pub struct Plain { var n: i32 }
pub struct Odd { var v: i32 }
extend Odd {
    fn op panic (const self) -> string { return "odd value" }
}

// Moves only, and owns a malloc'd i32: what an exception carries must be
// moved in and freed once (valgrind).
pub class Big {
    var p: unsafe *i32
    pub fn Big(self, v: i32) {
        unsafe { self.p = malloc(4) as unsafe *i32 }
        (*self.p) = v
    }
    @move
    fn Big(self, other: Self) {
        self.p = other.p
        unsafe { other.p = &null }
    }
    fn op delete(self) {
        if self.p != &null { unsafe { free(self.p as unsafe *void) } }
    }
    pub fn get(const self) -> i32 { return *self.p }
}

pub fn load(k: i32) panic -> i32 {
    if k == 0 { panic ConfigError { key: 7 } }
    if k == 1 { panic Plain { n: 3 } }
    if k == 3 { panic Odd { v: 3 } }
    return k * 2
}

pub fn check(k: i32) panic(Plain) {
    if k < 0 { panic Plain { n: k } }
}

pub fn big(k: i32) panic -> i32 {
    if k < 0 { panic Big(k) }
    return k
}
