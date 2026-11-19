// The original forms of moves out through a pointer that the hand-off
// tests now spell `cxx::std::move(...)`: each moves a MOVE value out of
// storage reached through a pointer, and each is SC182E with the place as
// written.

class Tok {
    pub var id: i32 = 0
    pub fn Tok(self, id: i32) {
        self.id = id
    }

    @move pub fn Tok(self, other: Self) {
        self.id = other.id
        other.id = 0
    }
}

class Pair {
    pub var a: Tok = Tok(1)
    pub var b: Tok = Tok(2)
}

class Holder {
    pub var p: Pair = Pair()
}

class Link {
    pub var link: *Pair
}

fn eat(t: Tok) -> i32 {
    return t.id
}


// partial_moves_run: field through a pointer
fn c1(q: *Pair) {
    // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:13: error [SC182E]: cannot move a value of type 'Tok' out of 'q->a': it is reached through a pointer or a reference
    var x = q->a
}

// partial_moves_run: field through a pointer, then refilled
fn c2(q: *Pair) {
    // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:13: error [SC182E]: cannot move a value of type 'Tok' out of 'q->a': it is reached through a pointer or a reference
    var x = q->a
    q->a = Tok(3)
}

// copy_fixit_any_route: by-value argument
fn c3(p: *Pair) {
    // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:9: error [SC182E]: cannot move a value of type 'Tok' out of 'p->a': it is reached through a pointer or a reference
    eat(p->a)
}

// cond_panic_flow: field of a pointer in a branch
fn c4(h: *Pair, c: bool) {
    if c {
    // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:17: error [SC182E]: cannot move a value of type 'Tok' out of 'h->a': it is reached through a pointer or a reference
        var k = h->a
    }
}

// partial_caller: returned through a pointer
fn c5(p: *Holder) -> Tok {
    // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:12: error [SC182E]: cannot move a value of type 'Tok' out of 'p->p.a': it is reached through a pointer or a reference
    return p->p.a
}

// partial_caller: a closure's pointer capture
fn c6() -> i32 {
    var h = Holder()
    // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:43: error [SC182E]: cannot move a value of type 'Tok' out of 'h->p.a': it is reached through a pointer or a reference
    var f = fn ()|*h| -> i32 { return eat(h->p.a) }
    return f()
}

// partial_owner: nested field through a pointer
fn c7(p: *Holder) {
    // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:13: error [SC182E]: cannot move a value of type 'Tok' out of 'p->p.a': it is reached through a pointer or a reference
    var a = p->p.a
}

// partial_owner: parenthesized dereference
fn c8(p: *Pair) {
    // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:14: error [SC182E]: cannot move a value of type 'Tok' out of '(*p).b': it is reached through a pointer or a reference
    var a = (*p).b
}

// partial_owner: whole pointee
fn c9(p: *Tok) {
    // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:13: error [SC182E]: cannot move a value of type 'Tok' out of '*p': it is reached through a pointer or a reference
    var a = *p
}

// partial_owner: whole pointee into an argument
fn c10(p: *Tok) -> i32 {
    // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:16: error [SC182E]: cannot move a value of type 'Tok' out of '*p': it is reached through a pointer or a reference
    return eat(*p)
}

// partial_owner: a pointer field of a local
fn c11(h: Link) {
    // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:13: error [SC182E]: cannot move a value of type 'Tok' out of 'h.link->a': it is reached through a pointer or a reference
    var a = h.link->a
}

// partial_owner: subscript of a pointer
fn c12(p: *Tok, n: usize) -> i32 {
    var total = 0
    for var i: usize = 0; i < n; ++i {
        // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:22: error [SC182E]: cannot move a value of type 'Tok' out of 'p[i]': it is reached through a pointer or a reference
        total += eat(p[i])
    }

    return total
}

// containers_and_pointers: whole pointer target of a pair
fn c13(q: *Pair) {
    // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:13: error [SC182E]: cannot move a value of type 'Pair' out of '*q': it is reached through a pointer or a reference
    var w = *q
}

// containers_and_pointers: initializer of a call argument
fn c14(q: *Pair) -> i32 {
    // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:17: error [SC182E]: cannot move a value of type 'Tok' out of 'q->a': it is reached through a pointer or a reference
    var r = eat(q->a)
    return r
}

// containers_and_pointers: element of a pointed-to array
fn c15(q: *[Tok; 2]) {
    // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:14: error [SC182E]: cannot move a value of type 'Tok' out of '(*q)[0]': it is reached through a pointer or a reference
    var f = (*q)[0]
}

// reinitialization: whole pointee, then assigned
fn c16(p: *Tok) {
    // CHECK: move_out_through_pointer_cases.k:[[@LINE+1]]:13: error [SC182E]: cannot move a value of type 'Tok' out of '*p': it is reached through a pointer or a reference
    var b = *p
    *p = Tok(2)
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
