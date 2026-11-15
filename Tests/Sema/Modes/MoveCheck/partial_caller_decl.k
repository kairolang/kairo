// What a call leaves moved-from is read from the function's DEFINITION,
// whichever declaration the call names.
//
//   1. a method declared in the class and defined out of line, below its
//      caller: the call leaves `h.a` moved-from
//   2. a free function declared first and defined below its caller
//   3. a function with no body in Kairo source (implemented in C or C++):
//      nothing can be read, so the worst is taken. A value of a move-only
//      type the body could move out of -- a non-const receiver, an `@inout`
//      argument, what a pointer to non-const points at -- is moved-from
//      after the call. A `const` receiver or parameter, a pointer to const
//      and a value of a copyable type are not.

class Str {
    pub var n: i32 = 0
    fn Str(self) { }
    @move fn Str(self, other: Self) { self.n = other.n; other.n = 0 }
}

class Holder {
    pub var a: Str
    pub var b: Str
    fn Holder(self) { }
    pub fn take_a(self) -> Str
    pub fn native_take(self) -> i32
    pub fn native_peek(const self) -> i32
}

fn drain(@inout h: Holder) -> Str
fn native_inout(@inout h: Holder) -> i32
fn native_ptr(h: *Holder) -> i32
fn native_const_ptr(h: *const Holder) -> i32
fn native_bytes(p: *i32, @inout n: i32) -> i32

// 1.
fn out_of_line() -> i32 {
    var h = Holder()
    var a = h.take_a()
    return h.a.n
// DIAG: partial_caller_decl.k:[[@LINE-1]]:12: error [SC052E]: 'h.a' is used after being moved
// DIAG: partial_caller_decl.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'h.a' was moved here, by the call to 'take_a'
// DIAG: partial_caller_decl.k:[[@LINE+60]]:41: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
}

// 2.
fn declared_first() -> i32 {
    var h = Holder()
    var b = drain(&h)
    return h.b.n
// DIAG: partial_caller_decl.k:[[@LINE-1]]:12: error [SC052E]: 'h.b' is used after being moved
// DIAG: partial_caller_decl.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'h.b' was moved here, by the call to 'drain'
// DIAG: partial_caller_decl.k:[[@LINE+51]]:44: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
}

// 3.
fn no_body_receiver() -> i32 {
    var h = Holder()
    var n = h.native_take()
    return n + h.a.n
// DIAG: partial_caller_decl.k:[[@LINE-1]]:16: error [SC052E]: 'h' is used after being moved
// DIAG: partial_caller_decl.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'h' was moved here, by the call to 'native_take', whose body cannot be read and is taken to move it
// DIAG: partial_caller_decl.k:[[@LINE-37]]:9: note [{{[A-Z0-9]+}}]: declared here with no body: write the parameter as 'move' if the function takes the value, or 'const' (a pointer to const) if it only reads it
}

fn no_body_inout() -> i32 {
    var h = Holder()
    var n = native_inout(&h)
    return n + h.a.n
// DIAG: partial_caller_decl.k:[[@LINE-1]]:16: error [SC052E]: 'h' is used after being moved
// DIAG: partial_caller_decl.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'h' was moved here, by the call to 'native_inout', whose body cannot be read and is taken to move it
// DIAG: partial_caller_decl.k:[[@LINE-41]]:1: note [{{[A-Z0-9]+}}]: declared here with no body: write the parameter as 'move' if the function takes the value, or 'const' (a pointer to const) if it only reads it
}

fn no_body_pointer(q: *Holder) -> i32 {
    var n = native_ptr(q)
    return n + q->a.n
// DIAG: partial_caller_decl.k:[[@LINE-1]]:16: error [SC052E]: '*q' is used after being moved
// DIAG: partial_caller_decl.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: '*q' was moved here, by the call to 'native_ptr', whose body cannot be read and is taken to move it
// DIAG: partial_caller_decl.k:[[@LINE-48]]:1: note [{{[A-Z0-9]+}}]: declared here with no body: write the parameter as 'move' if the function takes the value, or 'const' (a pointer to const) if it only reads it
}

fn no_body_reassigned() -> i32 {
    var h = Holder()
    var n = h.native_take()
    h = Holder()
    return n + h.a.n
}

fn no_body_const(q: *const Holder) -> i32 {
    var h = Holder()
    var n = h.native_peek() + native_const_ptr(q) + native_const_ptr(&h)
    return n + h.a.n + q->a.n
}

fn no_body_copyable() -> i32 {
    var x = 1
    var y = 2
    var n = native_bytes(&x, &y)
    return n + x + y
}

fn Holder::take_a(self) -> Str { return self.a }
fn drain(@inout h: Holder) -> Str { return h.b }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
