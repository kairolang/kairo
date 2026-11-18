// Element types for the vector tests, each made from an integer key and read
// back as one, so one generic test body runs over all of them.
//
// Tracked and RTracked are move-only and carry a state word: a move out of
// an object that is not live, a read of one, or a destroy of one that is
// neither live nor moved-from counts as an error, and LIVE counts objects
// whose destructor has not run. Tracked is not relocatable, so a vector moves
// it element by element; RTracked is @relocatable, so a vector moves its
// bytes.

import std::io

pub static LIVE: i64 = 0
pub static ERRS: i64 = 0

pub eval ALIVE: u64 = 0xA11CE
pub eval MOVED: u64 = 0x30BED
pub eval DEAD:  u64 = 0xDEAD

pub interface Elem {
    static fn make(k: i64) -> Self
    fn key(const self) -> i64
}

extend i32 impl Elem {
    static fn make(k: i64) -> i32 = k as i32
    fn key(const self) -> i64 = self as i64
}

extend u8 impl Elem {
    static fn make(k: i64) -> u8 = k as u8
    fn key(const self) -> i64 = self as i64
}

/// Three bytes, alignment 1.
@packed
pub struct P3 {
    pub var a: u8
    pub var b: u16
}

extend P3 impl Elem {
    static fn make(k: i64) -> P3 = P3 { a: k as u8, b: (k >> 8) as u16 }
    fn key(const self) -> i64 = (self.a as i64) | ((self.b as i64) << 8)
}

/// Sixty-four bytes.
pub struct B64 {
    pub var w: [i64; 8]
}

extend B64 impl Elem {
    static fn make(k: i64) -> B64 {
        var b = B64 { w: [k, k + 1, k + 2, k + 3, k + 4, k + 5, k + 6, k + 7] }
        return b
    }

    fn key(const self) -> i64 {
        if self.w[7] != self.w[0] + 7 {
            ERRS += 1
        }

        return self.w[0]
    }
}

/// Aligned above the shared empty header's 64.
@align(128)
pub struct A128 {
    pub var k: i64
}

extend A128 impl Elem {
    static fn make(k: i64) -> A128 = A128 { k: k }
    fn key(const self) -> i64 {
        if ((&self as usize) & 127) != 0 {
            ERRS += 1
        }

        return self.k
    }
}

extend string impl Elem {
    static fn make(k: i64) -> string = f"e{k}"
    fn key(const self) -> i64 {
        var v: i64 = 0
        for var i: usize = 1; i < self.size(); ++i {
            v = v * 10 + ((self.bytes()[i] - ('0' as u8)) as i64)
        }

        return v
    }
}

pub class Tracked {
    priv var state: u64
    priv var id:    i64

    pub fn Tracked(self, id: i64) {
        self.state = ALIVE
        self.id    = id
        LIVE += 1
    }

    @move pub fn Tracked(self, other: Self) {
        if other.state != ALIVE {
            ERRS += 1
        }

        self.state  = ALIVE
        self.id     = other.id
        other.state = MOVED
        LIVE += 1
    }

    pub fn op finally(self) {
        if self.state != ALIVE && self.state != MOVED {
            ERRS += 1
        }

        self.state = DEAD
        LIVE -= 1
    }

    pub fn get(const self) -> i64 {
        if self.state != ALIVE {
            ERRS += 1
        }

        return self.id
    }

    pub fn copy(const self) -> Tracked {
        return Tracked(self.get())
    }

    pub fn op == (const self, const o: Tracked) -> bool {
        return self.get() == o.get()
    }
}

extend Tracked impl Elem {
    static fn make(k: i64) -> Tracked = Tracked(k)
    fn key(const self) -> i64 = self.get()
}

extend Tracked impl Default {
    static fn make_default() -> Tracked = Tracked(0)
}

@relocatable
pub class RTracked {
    priv var state: u64
    priv var id:    i64

    pub fn RTracked(self, id: i64) {
        self.state = ALIVE
        self.id    = id
        LIVE += 1
    }

    @move pub fn RTracked(self, other: Self) {
        if other.state != ALIVE {
            ERRS += 1
        }

        self.state  = ALIVE
        self.id     = other.id
        other.state = MOVED
        LIVE += 1
    }

    pub fn op finally(self) {
        if self.state != ALIVE && self.state != MOVED {
            ERRS += 1
        }

        self.state = DEAD
        LIVE -= 1
    }

    pub fn get(const self) -> i64 {
        if self.state != ALIVE {
            ERRS += 1
        }

        return self.id
    }

    pub fn copy(const self) -> RTracked {
        return RTracked(self.get())
    }

    pub fn op == (const self, const o: RTracked) -> bool {
        return self.get() == o.get()
    }
}

extend RTracked impl Elem {
    static fn make(k: i64) -> RTracked = RTracked(k)
    fn key(const self) -> i64 = self.get()
}

extend RTracked impl Default {
    static fn make_default() -> RTracked = RTracked(0)
}

/// Prints `name: ok`, or what went wrong; nonzero when anything did.
pub fn report(const name: string, bad: i64) -> i32 {
    if bad == 0 && LIVE == 0 && ERRS == 0 {
        io::println(f"{name}: ok")
        return 0
    }

    io::println(f"{name}: FAIL bad={bad} live={LIVE} errs={ERRS}")
    LIVE = 0
    ERRS = 0
    return 1
}
