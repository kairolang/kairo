/// builtin/base/hash.k

import base::cmp::*
import base::intrinsics::*
import containers::slice::*

/// Seeded by the container; types only feed bytes into it.
pub class Hasher {
    priv var state: u64
    priv var seed:  u64

    pub fn Hasher(self, seed: u64) {
        __builtin_trap() // BODY-TODO
    }

    pub fn write(self, const b: [const u8;]) { // mixes the length in, so ("ab","c") != ("a","bc")
        __builtin_trap() // BODY-TODO
    }

    pub fn write_u64(self, v: u64) {
        __builtin_trap() // BODY-TODO
    }

    pub fn write_usize(self, v: usize) {
        __builtin_trap() // BODY-TODO
    }

    pub fn finish(const self) -> u64 {
        __builtin_trap() // BODY-TODO
    }
}

pub interface Hash derives Eq {
    fn hash(const self, @inout h: Hasher)
}
