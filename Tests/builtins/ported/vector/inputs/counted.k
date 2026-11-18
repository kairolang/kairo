// Shared fixtures for the ported vector tests: the check helpers and the
// element types. Counted and RCounted are move-only classes that count every
// construction, move, copy and destruction in the statics below, keep a state
// word that catches a read of a moved-from or destroyed object, and log the
// id of each destroyed object in destruction order. RCounted is @relocatable,
// so a vector moves its bytes; Counted is not, so a vector moves it one
// element at a time.

import std::io

pub static LIVE:   i64 = 0
pub static CTORS:  i64 = 0
pub static MOVES:  i64 = 0
pub static COPIES: i64 = 0
pub static DTORS:  i64 = 0
pub static ERRS:   i64 = 0
pub static LOGGED: usize = 0
pub static LOG:    [i64; 256]

static CASE: i32 = 0
static EXIT: i32 = 0

pub eval ALIVE: u64 = 0xA11CE
pub eval MOVED: u64 = 0x30BED
pub eval DEAD:  u64 = 0xDEAD

/// Records one check. A failing check prints its name and fixes the exit
/// code at its own ordinal, the first failure winning.
pub fn expect(ok: bool, const name: string) {
    CASE += 1
    if !ok {
        io::println(f"FAIL check {CASE}: {name}")
        if EXIT == 0 {
            EXIT = CASE
        }
    }
}

/// The exit code: 0 when every check passed.
pub fn finish() -> i32 {
    return EXIT
}

/// Zeroes the counters and the destruction log.
pub fn reset() {
    LIVE = 0
    CTORS = 0
    MOVES = 0
    COPIES = 0
    DTORS = 0
    ERRS = 0
    LOGGED = 0
}

/// Every object made since reset() is destroyed exactly once and none was
/// touched in a bad state.
pub fn expect_clean(const name: string) {
    expect(LIVE == 0 && ERRS == 0, name)
    var made = CTORS + MOVES
    expect(DTORS == made, f"{name}: destroyed {DTORS} of {made}")
}

pub fn log_id(id: i64) {
    if LOGGED < 256 {
        LOG[LOGGED] = id
    }

    LOGGED += 1
}

pub interface Elem {
    static fn make(k: i64) -> Self
    fn key(const self) -> i64
}

extend i32 impl Elem {
    static fn make(k: i64) -> i32 = k as i32
    fn key(const self) -> i64 = self
}

extend string impl Elem {
    static fn make(k: i64) -> string = f"e{k}"
    fn key(const self) -> i64 {
        var neg = self.size() > 1 && self.bytes()[1] == ('-' as u8)
        var v: i64 = 0
        for var i: usize = (if neg => 2 else => 1); i < self.size(); ++i {
            v = v * 10 + ((self.bytes()[i] - ('0' as u8)) as i64)
        }

        return if neg => -v else => v
    }
}

pub class Counted {
    priv var state: u64
    priv var id:    i64

    pub fn Counted(self, id: i64) {
        self.state = ALIVE
        self.id    = id
        LIVE += 1
        CTORS += 1
    }

    @move pub fn Counted(self, other: Self) {
        if other.state != ALIVE {
            ERRS += 1
        }

        self.state  = ALIVE
        self.id     = other.id
        other.state = MOVED
        LIVE += 1
        MOVES += 1
    }

    pub fn op finally(self) {
        if self.state != ALIVE && self.state != MOVED {
            ERRS += 1
        }

        if self.state == ALIVE {
            log_id(self.id)
        }

        self.state = DEAD
        LIVE -= 1
        DTORS += 1
    }

    pub fn get(const self) -> i64 {
        if self.state != ALIVE {
            ERRS += 1
        }

        return self.id
    }

    pub fn set(self, id: i64) {
        self.id = id
    }

    pub fn copy(const self) -> Counted {
        COPIES += 1
        return Counted(self.get())
    }

    pub fn op == (const self, const o: Counted) -> bool {
        return self.get() == o.get()
    }
}

extend Counted impl Elem {
    static fn make(k: i64) -> Counted = Counted(k)
    fn key(const self) -> i64 = self.get()
}

extend Counted impl Default {
    static fn make_default() -> Counted = Counted(0)
}

@relocatable
pub class RCounted {
    priv var state: u64
    priv var id:    i64

    pub fn RCounted(self, id: i64) {
        self.state = ALIVE
        self.id    = id
        LIVE += 1
        CTORS += 1
    }

    @move pub fn RCounted(self, other: Self) {
        if other.state != ALIVE {
            ERRS += 1
        }

        self.state  = ALIVE
        self.id     = other.id
        other.state = MOVED
        LIVE += 1
        MOVES += 1
    }

    pub fn op finally(self) {
        if self.state != ALIVE && self.state != MOVED {
            ERRS += 1
        }

        if self.state == ALIVE {
            log_id(self.id)
        }

        self.state = DEAD
        LIVE -= 1
        DTORS += 1
    }

    pub fn get(const self) -> i64 {
        if self.state != ALIVE {
            ERRS += 1
        }

        return self.id
    }

    pub fn copy(const self) -> RCounted {
        COPIES += 1
        return RCounted(self.get())
    }

    pub fn op == (const self, const o: RCounted) -> bool {
        return self.get() == o.get()
    }
}

extend RCounted impl Elem {
    static fn make(k: i64) -> RCounted = RCounted(k)
    fn key(const self) -> i64 = self.get()
}

extend RCounted impl Default {
    static fn make_default() -> RCounted = RCounted(0)
}

/// Builds [make(0) ... make(n-1)].
pub fn <E impl Elem> fill(n: i64) -> [E] {
    var v: [E]
    for var i: i64 = 0; i < n; ++i {
        v.push(E::make(i))
    }

    return v
}

/// True when the vector's keys are exactly `want`.
pub fn <E impl Elem> keys_are(const v: [E], const want: [i64]) -> bool {
    if v.size() != want.size() {
        return false
    }

    for var i: usize = 0; i < v.size(); ++i {
        if v[i].key() != want[i] {
            return false
        }
    }

    return true
}

/// The capacity a first allocation for `need` elements gets: at least `need`
/// and at least max(4, 64 / element size) (05-vector.md, Growth).
pub fn <E> grown_cap(need: usize) -> usize {
    var m: usize = 64 / sizeof E
    if m < 4 {
        m = 4
    }

    return if need < m => m else => need
}
