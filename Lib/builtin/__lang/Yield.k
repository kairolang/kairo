// coroutine.k -- exit 45
// The whole coroutine protocol in Kairo: the two names clang looks up in
// ::std, the awaiter, the promise, and a generator driven by the clang
// builtins. No C++ beyond what codegen emits.

module std {
    /// clang instantiates coroutine_traits<Ret, Params...> and reads promise_type.
    /// Only Kairo's coroutine types are answered; the primary is never defined.
    pub class <R, ...Args> coroutine_traits

    pub class <T, ...Args> coroutine_traits<Yield<T>, Args...> {
        pub type promise_type = YieldPromise<T>
    }

    pub class <P> coroutine_handle {
        pub var frame: unsafe *void

        static fn from_address(a: unsafe *void) -> coroutine_handle<P> {
            return coroutine_handle<P> { frame: a }
        }
    }
}

pub class Suspend {
    pub fn await_ready(self) -> bool { return false }
    pub fn <H> await_suspend(self, h: H) { }
    pub fn await_resume(self) { }
}

pub class <T> YieldPromise {
    pub var cur: *T

    pub fn get_return_object(self) -> Yield<T> {
        unsafe {
            return Yield<T>(__builtin_coro_promise(&self as unsafe *void, alignof(Self) as i32, true))
        }
    }
    pub fn initial_suspend(self) -> Suspend { return Suspend {} }
    pub fn final_suspend(self) -> Suspend { return Suspend {} }
    pub fn yield_value(self, @inout v: T) -> Suspend { self.cur = &v; return Suspend {} }
    pub fn return_void(self) { }
    pub fn unhandled_exception(self) { __builtin_trap() }
}

pub class <T> Yield {
    pub type promise_type = YieldPromise<T>
    var frame: unsafe *void

    pub fn Yield(self, f: unsafe *void) { self.frame = f }
    @move fn Yield(self, other: Self) { self.frame = other.frame; other.frame = &null }
    
    fn op delete(self) {
        unsafe { if self.frame != &null { __builtin_coro_destroy(self.frame) } }
    }

    pub fn next(self) -> bool {
        unsafe {
            __builtin_coro_resume(self.frame)
            return !__builtin_coro_done(self.frame)
        }
    }

    pub fn current(self) -> *T {
        unsafe {
            var p = __builtin_coro_promise(self.frame, alignof(YieldPromise<T>) as i32, false) as unsafe *YieldPromise<T>
            return p->cur
        }
    }
}