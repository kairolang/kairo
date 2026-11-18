// A transfer of a value that cannot be copied out of a place that cannot be
// moved from is SC182E (cannot copy): a `const` binding, a `const` parameter,
// a `const` pointee, the by-value copy of an element in a `const` container.
// A `const` binding cannot be passed to a `@move` parameter (SC301E). A
// NON_TRANSFER type cannot be moved at all (SC051E) and a COPY-only type
// cannot be passed to `@move` (functions-parameter-modes.mdx, @move is
// checked; ownership.mdx, Transfer Semantics and the final section).
// Cases from Rust tests/ui/moves/move-field-out-of-shared-self,
// move-out-of-shared-ref-deref, suggest-clone; nll/move-errors;
// borrowck/borrowck-move-out-of-struct-with-dtor.

import std

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) { self.id = id }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

class Cp {
    pub var id: i32 = 0
    fn Cp(self, id: i32) { self.id = id }
    @copy fn Cp(self, const other: Self) { self.id = other.id }
}

class Lock {
    fn Lock(self) { }
    @copy fn Lock(self, const other: Self) = delete
    @move fn Lock(self, other: Self) = delete
}

class Holder {
    pub var t: Tok
    pub var c: Cp
    fn Holder(self) { self.t = Tok(1); self.c = Cp(2) }
    fn peek_copy_const(const self) -> Cp { return self.c }
    fn peek_const(const self) -> Tok { return self.t } //! SC182E
    fn take(self) -> Tok { return self.t }
}

fn eat(t: Tok) -> i32 { return t.id }
fn eat_move(@move t: Tok) -> i32 { return t.id }
fn <T> gen_move(@move x: T) -> i32 { return 0 }

fn const_param_copied(const t: Tok) -> i32 {
    var u = t //! SC182E
    return u.id
}

fn const_param_passed_by_value(const t: Tok) -> i32 {
    return eat(t) //! SC182E
}

fn const_param_read_is_fine(const t: Tok) -> i32 {
    return t.id
}

fn const_local_copied() -> i32 {
    const a = Tok(1)
    var b = a //! SC182E
    return b.id
}

fn const_local_read_is_fine() -> i32 {
    const a = Tok(1)
    return a.id
}

fn const_pointee_copied(p: *const Tok) -> i32 {
    var b = *p //! SC182E
    return b.id
}

fn const_pointee_field_copied(const p: *const Holder) -> i32 {
    var t = p->t //! SC182E
    return t.id
}

fn const_pointee_copy_type_is_fine(const p: *const Holder) -> i32 {
    var c = p->c
    return c.id
}

fn move_only_to_move_param_is_fine() -> i32 {
    var a = Tok(1)
    return eat_move(a)
}

fn move_only_to_move_param_then_read() -> i32 {
    var a = Tok(1)
    var r = eat_move(a)
    return r + a.id //! SC052E
}

fn const_binding_to_move_param() -> i32 {
    const a = Tok(1)
    return eat_move(a) //! SC301E
}

fn generic_move_param_consumes_copy_type() -> i32 {
    var c = Cp(1)
    var r = gen_move(c)
    return r + c.id //! SC052E
}

fn generic_move_param_consumes_primitive() -> i32 {
    var n = 3
    var r = gen_move(n)
    return r + n //! SC052E
}

fn non_transfer_cannot_be_copied() -> i32 {
    var l = Lock()
    var m = l //! SC182E
    return 0
}

fn non_transfer_cannot_be_passed() -> i32 {
    var l = Lock()
    return take_lock(l) //! SC182E
}

fn take_lock(l: Lock) -> i32 { return 0 }

fn non_transfer_by_const_is_fine() -> i32 {
    var l = Lock()
    return peek_lock(l)
}

fn peek_lock(const l: Lock) -> i32 { return 0 }

fn non_transfer_std_move() -> i32 {
    var l = Lock()
    var m = std::move(l) //! SC051E
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: copy_and_move_errors.k:37:{{[0-9]+}}: error [SC182E]:
// CHECK: copy_and_move_errors.k:46:{{[0-9]+}}: error [SC182E]:
// CHECK: copy_and_move_errors.k:51:{{[0-9]+}}: error [SC182E]:
// CHECK: copy_and_move_errors.k:60:{{[0-9]+}}: error [SC182E]:
// CHECK: copy_and_move_errors.k:70:{{[0-9]+}}: error [SC182E]:
// CHECK: copy_and_move_errors.k:75:{{[0-9]+}}: error [SC182E]:
// CHECK: copy_and_move_errors.k:92:{{[0-9]+}}: error [SC052E]:
// CHECK: copy_and_move_errors.k:97:{{[0-9]+}}: error [SC301E]:
// CHECK: copy_and_move_errors.k:103:{{[0-9]+}}: error [SC052E]:
// CHECK: copy_and_move_errors.k:109:{{[0-9]+}}: error [SC052E]:
// CHECK: copy_and_move_errors.k:114:{{[0-9]+}}: error [SC182E]:
// CHECK: copy_and_move_errors.k:120:{{[0-9]+}}: error [SC182E]:
// CHECK: copy_and_move_errors.k:134:{{[0-9]+}}: error [SC051E]:
