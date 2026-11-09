/// --- The Kairo Project ----------------- Lib/builtin/coro/generator.k --- ///
///
///   The Yield lang item (a generator) and its promise type, YieldPromise.
///   One file: each names the other. The file is not `yield.k` because
///   `yield` is a keyword.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import coro::suspend::*

ffi "c++" import "coroutine"

/// The coroutine promise behind a generator: C++ coroutine plumbing for `Yield<T>`.
///
/// `yield v` is lowered to `yield_value`, which records the address of `v` in `cur`. The compiler
/// and clang's coroutine machinery call the other members; user code does not.
pub class <T> YieldPromise {
    /// The address of the most recently yielded value; valid until the generator resumes.
    pub var cur: *T

    /// Builds the `Yield<T>` handle for this coroutine's frame.
    pub inline fn get_return_object(self) -> Yield<T> {
        unsafe {
            return Yield<T>(__builtin_coro_promise(&self as unsafe *void, alignof(Self) as i32, true))
        }
    }

    /// Suspends at the start, so nothing runs until the first `next()`.
    pub inline fn initial_suspend(self) -> Suspend { return Suspend {} }
    /// Suspends at the end, keeping the frame alive so `Yield` can destroy it.
    @no_unwind pub inline fn final_suspend(self) -> Suspend { return Suspend {} }

    /// Handles `yield v`: records the address of `v` and suspends.
    ///
    /// \param v  Taken `@inout`: the reader sees the generator's own value, not a copy.
    pub inline fn yield_value(self, @inout v: T) -> Suspend {
        self.cur = &v
        return Suspend {}
    }

    /// Handles falling off the end of the generator body.
    pub inline fn return_void(self) { }
    /// Traps (`__builtin_trap`): generators do not propagate exceptions.
    pub inline fn unhandled_exception(self) { __builtin_trap() }
}

/// The handle a generator function returns: the `Yield` lang item, the target of `yield`.
///
/// A function containing `yield` returns one; a `for` loop over it drives `next()` and reads
/// `current()`. Move-only; destroying the handle destroys the coroutine frame.
///
/// \see YieldPromise
pub class <T> Yield {
    /// The promise type clang's coroutine machinery looks up.
    pub type promise_type = YieldPromise<T>

    var frame: unsafe *void

    /// Wraps a coroutine frame; called by `YieldPromise::get_return_object`.
    pub inline fn Yield(self, f: unsafe *void) { self.frame = f }

    @no_unwind @move inline fn Yield(self, other: Self) {
        self.frame  = other.frame
        other.frame = &null
    }

    @no_unwind inline fn op delete(self) {
        unsafe { if self.frame != &null { __builtin_coro_destroy(self.frame) } }
    }

    /// Resumes the generator to its next `yield`. Returns false once the body has finished, true
    /// when
    /// `current()` holds a new value.
    ///
    /// \note Resuming a finished generator is undefined in clang's coroutine model; stop at the
    /// first false.
    pub inline fn next(self) -> bool {
        unsafe {
            __builtin_coro_resume(self.frame)
            return !__builtin_coro_done(self.frame)
        }
    }

    /// Returns a pointer to the most recently yielded value.
    ///
    /// Valid only after `next()` returned true and until the next `next()` call.
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
