import string::*

/// `a..b` / `a..=b`. Field order is evaluation order: RangeLowering builds a
/// range as a designated initializer, and C++ evaluates those in declaration
/// order. Keep `begin` before `end`.
pub struct <T> Range {
    var begin:     T
    var end:       T
    var inclusive: bool
}

/// `a..`, and `..` as `begin: 0`. Only valid as a subscript index.
pub struct <T> RangeFrom {
    var begin: T
}

/// `..b` / `..=b`. Only valid as a subscript index.
pub struct <T> RangeTo {
    var end:       T
    var inclusive: bool
}

pub struct <T> Panic   { var value: T }
pub struct PanicRaise { var payload: *void }
pub struct PanicCatch { var payload: *void }
pub enum Ordering derives i8 {
    Less    = -1,
    Equal   = 0,
    Greater = 1,
}
pub struct <T> Null    { var value: T; var has: bool }
pub struct <T> Future  { var state: *void }

/// What `byte` is in C++: a scoped enum over u8, which is `std::byte`'s own
/// shape (no arithmetic, explicit conversions) without needing <cstddef>.
/// Kairo bypasses clang's preprocessor, so an emitted TU cannot #include
/// one; a builtin declaration the plan emits like any other can. Named
/// `Byte` because `byte` is a type keyword, not an identifier. Sema keeps
/// its own `byte` rules; only the C++ spelling points here.
pub enum Byte derives u8 {}
pub struct BigInt   { var limbs: *u64; var len: usize; var neg: bool }
pub struct BigFloat { var mant: BigInt; var exp: i64 }
pub struct AssertFail { var message: string }
// // coroutine.k -- exit 45
// // The whole coroutine protocol in Kairo: the two names clang looks up in
// // ::std, the awaiter, the promise, and a generator driven by the clang
// // builtins. No C++ beyond what codegen emits.

ffi "c++" import "coroutine"

/// The awaiter every suspension point uses: always suspends, does nothing on
/// suspend or resume. clang requires the awaiter of `final_suspend` to be
/// non-throwing in all three calls, so all three are marked.
pub class Suspend {
    @no_unwind pub inline fn await_ready(self) -> bool { return false }
    @no_unwind pub inline fn <H> await_suspend(self, h: H) { }
    @no_unwind pub inline fn await_resume(self) { }
}

pub class <T> YieldPromise {
    pub var cur: *T

    pub inline fn get_return_object(self) -> Yield<T> {
        unsafe {
            return Yield<T>(__builtin_coro_promise(&self as unsafe *void, alignof(Self) as i32, true))
        }
    }

    pub inline fn initial_suspend(self) -> Suspend { return Suspend {} }
    @no_unwind pub inline fn final_suspend(self) -> Suspend { return Suspend {} }

    pub inline fn yield_value(self, @inout v: T) -> Suspend {
        self.cur = &v
        return Suspend {}
    }

    pub inline fn return_void(self) { }
    pub inline fn unhandled_exception(self) { __builtin_trap() }
}

pub class <T> Yield {
    pub type promise_type = YieldPromise<T>

    var frame: unsafe *void

    pub inline fn Yield(self, f: unsafe *void) { self.frame = f }

    @no_unwind @move inline fn Yield(self, other: Self) {
        self.frame  = other.frame
        other.frame = &null
    }

    @no_unwind inline fn op delete(self) {
        unsafe { if self.frame != &null { __builtin_coro_destroy(self.frame) } }
    }

    pub inline fn next(self) -> bool {
        unsafe {
            __builtin_coro_resume(self.frame)
            return !__builtin_coro_done(self.frame)
        }
    }

    pub inline fn current(self) -> *T {
        unsafe {
            var p = __builtin_coro_promise(self.frame, alignof(YieldPromise<T>) as i32, false) as unsafe *YieldPromise<T>
            return p->cur
        }
    }
}

// pub class <T> Yield {
//     pub var frame: unsafe *void
// }