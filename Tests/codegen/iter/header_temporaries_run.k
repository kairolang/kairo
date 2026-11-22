// Every temporary created in the header of a `for` loop lives until the loop
// ends: the receiver of the iterated call, its arguments, and what those are
// built from. A generator borrows its receiver and its `const` parameters,
// so it reads them on every step; ended at the header, they are freed memory
// under the loop.
//
// Tok counts the objects alive (`live`) and records, when one is destroyed,
// which iteration the loop was in (`died_at`) and how many were destroyed
// (`deaths`). Each case checks that the header's temporaries are alive in
// every iteration and that each is destroyed exactly once, after the last
// iteration, on a normal end, a `break`, a `return` and a panic.

var live:    i32 = 0
var deaths:  i32 = 0
var step:    i32 = 0
var died_at: i32 = 0

class Tok {
    pub var id: i32

    pub fn Tok(self, id: i32) {
        self.id = id
        live += 1
    }

    @move
    pub fn Tok(self, o: Tok) {
        self.id = o.id
        o.id    = -1
    }

    fn op finally(self) {
        if self.id >= 0 {
            live    -= 1
            deaths  += 1
            died_at = step
        }
    }

    pub fn view(const self) -> *const Tok {
        return &self
    }

    /// Borrows `self` for as long as it runs.
    pub fn count(const self) -> yield i32 {
        for var i = 0; i < 3; i++ {
            yield self.id + i
        }
    }

    /// Borrows `lo` and `lim` too.
    pub fn span(const self, lo: *const Tok, const lim: Tok) -> yield i32 {
        for var i = lo->id; i < lim.id; i++ {
            yield i + self.id
        }
    }

    pub fn op in (const self) -> yield i32 {
        for var i = 0; i < 3; i++ {
            yield self.id + i
        }
    }
}

extend Tok {
    pub fn ext_count(const self) -> yield i32 {
        for var i = 0; i < 3; i++ {
            yield self.id + i
        }
    }
}

class Row {
    var a: [i32; 3]
    pub var tag: Tok

    pub fn Row(self, base: i32) {
        self.a   = [base, base + 1, base + 2]
        self.tag = Tok(base)
    }

    pub fn cells(const self) -> [const i32;] {
        return self.a
    }
}

fn make(id: i32) -> Tok {
    return Tok(id)
}

fn wrap(t: Tok) -> Tok {
    return Tok(t.id + 1)
}

fn reset() {
    deaths  = 0
    step    = 0
    died_at = -1
}

/// One loop is over: `n` temporaries died, all after iteration `last`.
fn ended(n: i32, last: i32) -> bool {
    return live == 0 && deaths == n && died_at == last
}

// The receiver of a generator method.
fn receiver() -> i32 {
    reset()
    var sum = 0
    for x in make(10).count() {
        step += 1
        if live != 1 { return 1 }
        sum += x
    }

    if sum != 33 || !ended(1, 3) { return 2 }
    return 0
}

// The receiver of an extension's generator method.
fn ext_receiver() -> i32 {
    reset()
    var sum = 0
    for x in make(20).ext_count() {
        step += 1
        if live != 1 { return 3 }
        sum += x
    }

    if sum != 63 || !ended(1, 3) { return 4 }
    return 0
}

// An argument the generator takes by `const`, and the temporaries an
// argument is built from: two arguments with effects are bound in order,
// and what they are bound to lives as long.
fn arguments() -> i32 {
    reset()
    var a   = Tok(100)
    var sum = 0
    for x in a.span(wrap(make(0)).view(), make(4)) {
        step += 1
        if live != 3 || deaths != 1 { return 5 }
        sum += x
    }

    // make(0) moves into wrap's parameter, which ends with the call;
    // wrap's result and make(4) live for the loop.
    if sum != 306 || live != 1 || deaths != 3 || died_at != 3 { return 6 }
    return 0
}

// A generator over a temporary, itself the receiver of the iterated call.
fn nested() -> i32 {
    reset()
    var sum = 0
    for x in wrap(make(30)).count() {
        step += 1
        if live != 1 || deaths != 1 { return 7 }
        sum += x
    }

    // wrap's parameter ended with the call; its result ends here.
    if sum != 96 || !ended(2, 3) { return 8 }
    return 0
}

fn broken() -> i32 {
    reset()
    for x in make(40).count() {
        step += 1
        if live != 1 { return 9 }
        if x == 41 { break }
    }

    if !ended(1, 2) { return 10 }
    return 0
}

fn returns_early() -> i32 {
    for x in make(50).count() {
        step += 1
        if x == 51 { return live }
    }

    return -1
}

fn returned() -> i32 {
    reset()
    if returns_early() != 1 || !ended(1, 2) { return 11 }
    return 0
}

fn fails() panic(i32) -> i32 {
    for x in make(60).count() {
        step += 1
        if x == 61 { panic live }
    }

    return 0
}

fn panicked() -> i32 {
    reset()
    var seen = 0
    try { seen = fails() } catch e: i32 { seen = e + 100 }
    if seen != 101 || !ended(1, 2) { return 12 }
    return 0
}

// A record's `op in` over a temporary: the object is the loop's.
fn op_in() -> i32 {
    reset()
    var sum = 0
    for x in make(70) {
        step += 1
        if live != 1 { return 13 }
        sum += x
    }

    if sum != 213 || !ended(1, 3) { return 14 }
    return 0
}

// A slice of a temporary's storage.
fn slice_view() -> i32 {
    reset()
    var sum = 0
    for x in Row(5).cells() {
        step += 1
        if live != 1 { return 15 }
        sum += x
    }

    if sum != 18 || !ended(1, 3) { return 16 }
    return 0
}

// Range bounds read off temporaries.
fn range_bounds() -> i32 {
    reset()
    var sum = 0
    for i in make(1).id..make(4).id {
        step += 1
        if live != 2 { return 17 }
        sum += i
    }

    if sum != 6 || !ended(2, 3) { return 18 }
    return 0
}

// A generic body is one C++ template.
fn <T> generic(seed: T, id: i32) -> i32 {
    reset()
    var keep = seed
    var sum  = 0
    for x in make(id).count() {
        step += 1
        if live != 1 { return 19 }
        sum += x
    }

    if sum != 6 || !ended(1, 3) { return 20 }
    return 0
}

// A loop inside a generator: the temporaries live in its frame across
// every suspension, and an abandoned generator ends them.
fn relay() -> yield i32 {
    for x in make(80).count() {
        yield x
    }
}

fn in_generator() -> i32 {
    reset()
    var sum = 0
    for x in relay() {
        step += 1
        if live != 1 { return 21 }
        sum += x
    }

    if sum != 243 || !ended(1, 3) { return 22 }

    reset()
    for x in relay() {
        step += 1
        break
    }

    if !ended(1, 1) { return 23 }
    return 0
}

fn main() -> i32 {
    var r = receiver()
    if r == 0 { r = ext_receiver() }
    if r == 0 { r = arguments() }
    if r == 0 { r = nested() }
    if r == 0 { r = broken() }
    if r == 0 { r = returned() }
    if r == 0 { r = panicked() }
    if r == 0 { r = op_in() }
    if r == 0 { r = slice_view() }
    if r == 0 { r = range_bounds() }
    if r == 0 { r = generic<i64>(9, 1) }
    if r == 0 { r = in_generator() }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// Each temporary is a local of the loop's own block, declared ahead of the
// generator in evaluation order; a header that is a plain name declares
// nothing more.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: signed int receiver() noexcept {
// CXX:       Tok __kairo_ord[[R:[0-9]+]] ={{ ?}}::header_temporaries_run::make(10);
// CXX:       __kairo_ord[[R]].count( ::__kairo_each<signed int> {
// CXX-LABEL: signed int ext_receiver() noexcept {
// CXX:       Tok __kairo_ord[[E:[0-9]+]] ={{ ?}}::header_temporaries_run::make(20);
// CXX:       ext_count((& __kairo_ord[[E]]), ::__kairo_each<signed int> {
// CXX-LABEL: signed int arguments() noexcept {
// CXX:       Tok __kairo_ord[[W:[0-9]+]] ={{ ?}}::header_temporaries_run::wrap({{ ?}}::header_temporaries_run::make(0));
// CXX-NEXT:  Tok * __kairo_ord[[V:[0-9]+]] = __kairo_ord[[W]].view();
// CXX-NEXT:  Tok __kairo_ord[[L:[0-9]+]] ={{ ?}}::header_temporaries_run::make(4);
// CXX:       a.span(__kairo_ord[[V]], static_cast<{{ ?}}::header_temporaries_run::Tok &&>(__kairo_ord[[L]]), ::__kairo_each<signed int> {
// CXX-LABEL: signed int range_bounds() noexcept {
// CXX:       Tok __kairo_ord[[B:[0-9]+]] ={{ ?}}::header_temporaries_run::make(1);
// CXX-NEXT:  signed int __kairo_lo{{[0-9]+}} = __kairo_ord[[B]].id;

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2
// RUN: %t.o2.exe
