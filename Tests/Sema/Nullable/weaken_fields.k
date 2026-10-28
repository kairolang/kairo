// G12 (Compiler/Sema/NULLABLE.md 3.4): a field path `foo.data` loses its
// check when a call may write it through its owner. A method taking a
// mutable `self` may write any field of its receiver, so it weakens every
// path under the receiver; a `const self` method does not. Covered: a
// mutable-self call on the path's owner (`f.reset()` weakens `f.cache`),
// on a PREFIX two levels up (`s.foo.reset()` weakens `s.foo.cache`), on
// `self` inside a method, and through a user operator (`f += 1`, a
// mutable `op +=`); a nullable receiver narrowed by its own check stays
// proven (the call can change its fields, not make it null), while its
// field does not; and what stays proven: a `const self` call, a sibling
// path the call cannot reach (`s.n` across `s.foo.reset()`), a call
// through a pointer (`p->reset()` writes what `p` points at, which no
// check here is about), and a re-check after the call. A mutable-self
// call in a loop body weakens the receiver's paths at the loop's head.

class Foo {
    pub var v: i32 = 1
    pub var cache: i32? = null
    pub fn Foo(self) { }
    pub fn reset(self) { self.cache = null }
    pub fn peek(const self) -> i32 { return self.v }
    pub fn op +=(self, k: i32) { self.v += k }
    pub fn twice(self) -> i32 {
        if self.cache? {
            self.reset()
            return self.cache + 0
        }
        return 0
    }
}
struct S { pub var foo: Foo = Foo(); pub var n: i32? = null }

fn bad_owner() -> i32 {
    var f = Foo()
    if f.cache? {
        f.reset()
        return f.cache + 0
    }
    return 0
}

fn bad_prefix(s: S) -> i32 {
    if s.foo.cache? {
        s.foo.reset()
        return s.foo.cache + 0
    }
    return 0
}

fn bad_user_operator() -> i32 {
    var f = Foo()
    f.cache = 2
    f += 1
    return f.cache + 0
}

fn bad_nullable_receiver_field() -> i32 {
    var o: Foo? = Foo()
    if o? {
        o.cache = 1
        o.reset()
        var a = o.v + 0
        return o.cache + a
    }
    return 0
}

fn ok_const_self() -> i32 {
    var f = Foo()
    if f.cache? {
        f.peek()
        return f.cache + 0
    }
    return 0
}

fn ok_sibling(s: S) -> i32 {
    if s.n? {
        s.foo.reset()
        return s.n + 0
    }
    return 0
}

fn ok_pointer_receiver(p: *Foo) -> i32 {
    var f = Foo()
    f.cache = 2
    p->reset()
    return f.cache + 0
}

fn ok_recheck() -> i32 {
    var f = Foo()
    f.reset()
    if f.cache? { return f.cache + 0 }
    return 0
}

fn bad_loop(c: i32) -> i32 {
    var f = Foo()
    f.cache = 1
    var r = 0
    while r < c {
        r += f.cache
        f.reset()
    }
    return r
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_fields.k:26:20: error [SC001E]: 'self.cache' may be null here; check it with 'if self.cache?' first
// DIAG-NEXT: weaken_fields.k:25:13: note [{{.*}}]: this call takes what holds 'self.cache' as a mutable 'self', so it may change 'self.cache'
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_fields.k:37:16: error [SC001E]: 'f.cache' may be null here; check it with 'if f.cache?' first
// DIAG-NEXT: weaken_fields.k:36:9: note [{{.*}}]: this call takes what holds 'f.cache' as a mutable 'self', so it may change 'f.cache'
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_fields.k:45:16: error [SC001E]: 's.foo.cache' may be null here; check it with 'if s.foo.cache?' first
// DIAG-NEXT: weaken_fields.k:44:9: note [{{.*}}]: this call takes what holds 's.foo.cache' as a mutable 'self', so it may change 's.foo.cache'
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_fields.k:54:12: error [SC001E]: 'f.cache' may be null here; check it with 'if f.cache?' first
// DIAG-NEXT: weaken_fields.k:53:5: note [{{.*}}]: this call takes what holds 'f.cache' as a mutable 'self', so it may change 'f.cache'
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_fields.k:63:16: error [SC001E]: 'o.cache' may be null here; check it with 'if o.cache?' first
// DIAG-NEXT: weaken_fields.k:61:9: note [{{.*}}]: this call takes what holds 'o.cache' as a mutable 'self', so it may change 'o.cache'
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_fields.k:104:14: error [SC001E]: 'f.cache' may be null here; check it with 'if f.cache?' first
// DIAG-NEXT: weaken_fields.k:105:9: note [{{.*}}]: 'f.cache' may be changed in the loop here, so it may be null at the top of the loop
// DIAG-NOT: {{error|warning}}
