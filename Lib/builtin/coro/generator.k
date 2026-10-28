/// --- The Kairo Project ----------------- Lib/builtin/coro/generator.k --- ///
///
///   The Yield lang item (a generator) and its promise type, YieldPromise.
///   One file: each names the other. The file is not `yield.k` because
///   `yield` is a keyword.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import coro::suspend::*

ffi "c++" import "coroutine"

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
