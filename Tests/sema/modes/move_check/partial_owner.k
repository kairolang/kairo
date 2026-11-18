// A move out of storage that is not a whole local: a field of `self`, a
// field reached through a pointer, a dereference, an element. The move is
// allowed, and the storage it came out of is moved-from until it is assigned
// again.
//
//   1. `self`: a moved field is gone, its siblings are not; assigning the
//      field makes `self` whole; a method call on `self` reads all of it
//   2. `@inout` parameter: tracked as a by-value one is
//   3. through a pointer: `p->a` and `(*p).a` name the same part; the
//      pointer itself stays readable, and rebinding it forgets the pointee
//   4. `*p` moved whole
//   5. an element: the container it came out of is moved-from, whatever the
//      index; a container that is a field leaves its siblings readable; a
//      loop moving `v[i]` reads the moved-from container on its next pass
//   6. a pointer field: `h.link->a` is a part of what `h.link` points at
//   7. `p[i]` on a pointer is not tracked: the storage behind a pointer is
//      managed by hand, element by element, as a container's buffer is

class Str {
    pub var n: i32 = 0
    fn Str(self) { }
    fn Str(self, n: i32) { self.n = n }
    @move fn Str(self, other: Self) { self.n = other.n; other.n = 0 }
}

class Pair {
    pub var a: Str
    pub var b: Str
    fn Pair(self) { }
}

class Holder {
    pub var p:     Pair
    pub var items: [Str; 2]
    pub var link:  unsafe *Pair = &null
    fn Holder(self) { }
}

fn eat(s: Str) -> i32 { return s.n }
fn peek(s: *Str) { }
fn peek_pair(p: unsafe *Pair) { }
fn peek_ptr(p: *Holder) { }

// 1.
extend Holder {
    fn touch(self) { }

    fn self_reuse(self) -> i32 {
        var a = self.p.a
        return self.p.a.n
// DIAG: partial_owner.k:[[@LINE-1]]:16: error [SC052E]: 'self.p.a' is used after being moved
// DIAG: partial_owner.k:[[@LINE-3]]:17: note [{{[A-Z0-9]+}}]: 'self.p.a' was moved here, into 'a'
    }

    fn self_sibling(self) -> i32 {
        var a = self.p.a
        return self.p.b.n
    }

    fn self_reassign(self) -> i32 {
        var a = self.p.a
        self.p.a = Str(1)
        return self.p.a.n
    }

    fn self_whole(self) {
        eat(self.p.a)
        self.touch()
// DIAG: partial_owner.k:[[@LINE-1]]:9: error [SC052E]: 'self' is used after its part 'self.p.a' was moved
// DIAG: partial_owner.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'self.p.a' was moved here, into a by-value parameter
    }

    fn self_join(self, c: bool) -> i32 {
        if c {
            eat(self.p.b)
        }

        return self.p.b.n
// DIAG: partial_owner.k:[[@LINE-1]]:16: error [SC052E]: 'self.p.b' is used after being moved
// DIAG: partial_owner.k:[[@LINE-5]]:17: note [{{[A-Z0-9]+}}]: 'self.p.b' was moved here, into a by-value parameter
    }
}

// 2.
fn inout_reuse(@inout h: Holder) -> i32 {
    var a = h.p.a
    return h.p.a.n
// DIAG: partial_owner.k:[[@LINE-1]]:12: error [SC052E]: 'h.p.a' is used after being moved
// DIAG: partial_owner.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'h.p.a' was moved here, into 'a'
}

fn inout_reassign(@inout h: Holder) -> i32 {
    var a = h.p.a
    h.p.a = Str(2)
    return h.p.a.n
}

// 3.
fn arrow_reuse(p: *Holder) -> i32 {
    var a = p->p.a
    return p->p.a.n
// DIAG: partial_owner.k:[[@LINE-1]]:12: error [SC052E]: 'p->p.a' is used after being moved
// DIAG: partial_owner.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'p->p.a' was moved here, into 'a'
}

fn arrow_sibling(p: *Holder) -> i32 {
    var a = p->p.a
    return p->p.b.n
}

fn arrow_reassign(p: *Holder) -> i32 {
    var a = p->p.a
    p->p.a = Str(3)
    return p->p.a.n
}

fn arrow_then_star(p: *Pair) -> i32 {
    var a = p->a
    return (*p).a.n
// DIAG: partial_owner.k:[[@LINE-1]]:14: error [SC052E]: 'p->a' is used after being moved
// DIAG: partial_owner.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'p->a' was moved here, into 'a'
}

fn star_then_arrow(p: *Pair) -> i32 {
    var a = (*p).b
    return p->b.n
// DIAG: partial_owner.k:[[@LINE-1]]:12: error [SC052E]: 'p->b' is used after being moved
// DIAG: partial_owner.k:[[@LINE-3]]:14: note [{{[A-Z0-9]+}}]: 'p->b' was moved here, into 'a'
}

fn pointer_value_stays(p: *Holder) {
    var a = p->p.a
    peek_ptr(p)
}

fn pointer_rebound(p: *Pair, q: *Pair) -> i32 {
    var *r = p
    var a = r->a
    r = q
    return r->a.n
}

// 4.
fn star_reuse(p: *Str) -> i32 {
    var a = *p
    return eat(*p)
// DIAG: partial_owner.k:[[@LINE-1]]:17: error [SC052E]: '*p' is used after being moved
// DIAG: partial_owner.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: '*p' was moved here, into 'a'
}

fn star_reassign(p: *Str) -> i32 {
    var a = *p
    *p = Str(4)
    return p->n
}

// 5.
fn elem_reuse() -> i32 {
    var v: [Str; 2]
    var a = v[0]
    return v[1].n
// DIAG: partial_owner.k:[[@LINE-1]]:12: error [SC052E]: 'v' is used after 'v[0]' was moved out of it
// DIAG: partial_owner.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'v[0]' was moved here, into 'a'
}

fn elem_field() -> i32 {
    var h = Holder()
    var a = h.items[0]
    var n = h.p.a.n
    return n + h.items[1].n
// DIAG: partial_owner.k:[[@LINE-1]]:16: error [SC052E]: 'h.items' is used after 'h.items[0]' was moved out of it
// DIAG: partial_owner.k:[[@LINE-4]]:13: note [{{[A-Z0-9]+}}]: 'h.items[0]' was moved here, into 'a'
}

fn elem_self_field(@inout h: Holder) -> i32 {
    eat(h.items[1])
    peek(&h.items[0])
// DIAG: partial_owner.k:[[@LINE-1]]:11: error [SC052E]: 'h.items' is used after 'h.items[1]' was moved out of it
// DIAG: partial_owner.k:[[@LINE-3]]:9: note [{{[A-Z0-9]+}}]: 'h.items[1]' was moved here, into a by-value parameter
    return 0
}

fn elem_loop() -> i32 {
    var v: [Str; 2]
    var n = 0
    var i = 0
    while i < 2 {
        n += eat(v[i])
// DIAG: partial_owner.k:[[@LINE-1]]:18: error [SC052E]: 'v' is used after 'v[i]' was moved out of it
// DIAG: partial_owner.k:[[@LINE-2]]:18: note [{{[A-Z0-9]+}}]: 'v[i]' was moved here, into a by-value parameter
        i += 1
    }

    return n
}

// 6.
fn link_reuse(@inout h: Holder) -> i32 {
    var a = h.link->a
    return h.link->a.n
// DIAG: partial_owner.k:[[@LINE-1]]:12: error [SC052E]: 'h.link->a' is used after being moved
// DIAG: partial_owner.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'h.link->a' was moved here, into 'a'
}

fn link_sibling(@inout h: Holder) -> i32 {
    var a = h.link->a
    peek_pair(h.link)
    return h.link->b.n + h.p.a.n
}

// 7.
fn raw_elem(p: *Str, n: usize) -> i32 {
    var total = 0
    for var i: usize = 0; i < n; ++i {
        total += eat(p[i])
    }

    return total + p[0].n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
