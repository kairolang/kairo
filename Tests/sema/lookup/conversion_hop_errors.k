// The limits of member lookup through an `@implicit op as`:
//   - one hop: a member of what the conversion's result converts to is not
//     found (`far`), and the error is the plain one;
//   - a name no conversion's result has keeps the plain error (`nothing`);
//   - a const receiver uses a `const self` conversion only, so a member
//     only the `self` conversion's result has is no member, with a note
//     at that conversion (`sort`);
//   - two conversions a receiver may use whose results both have the name
//     are ambiguous, naming both (`both` on a const receiver; a mutable
//     one takes the `self` conversion and has no tie);
//   - the type's own member wins (`own` is Buf's, a `bool`);
//   - a field, a `?.` step, a compound assignment, a unary operator,
//     indexing and `in` are not looked up through a conversion, and an
//     infix operator of the result that does not take the operands leaves
//     the type's own "no operator" error.

class <T> View {
    pub var n: usize
    pub var field: i32
    pub fn View(self, n: usize) { self.n = n; self.field = 0 }
    pub fn sort(self) { }
    pub fn size(const self) -> usize { return self.n }
    pub fn both(const self) -> usize { return 1 }
    pub fn own(const self) -> usize { return 1 }
    pub fn op += (self, v: usize) { }
    pub fn op - (const self) -> usize { return 0 }
    pub fn op [] (const self, i: usize) -> usize { return i }
    pub fn op in (const self, v: usize) -> bool { return true }
    pub fn op == (const self, const o: View<T>) -> bool { return true }
}

class <T> View<const T> {
    pub var n: usize
    pub fn View(self, n: usize) { self.n = n }
    pub fn size(const self) -> usize { return self.n }
    pub fn both(const self) -> usize { return 1 }
}

class Far {
    pub fn Far(self) { }
    pub fn far(const self) -> usize { return 4 }
}

class Other {
    pub fn Other(self) { }
    pub fn both(const self) -> usize { return 2 }
    @implicit pub fn op as (const self) -> Far { return Far() }
}

class <T> Buf {
    pub fn Buf(self) { }
    pub fn own(const self) -> bool { return true }
    @implicit pub fn op as (const self) -> View<const T> { return View<const T>(1) }
    @implicit pub fn op as (self) -> View<T> { return View<T>(1) }
    @implicit pub fn op as (const self) -> Other { return Other() }
    pub fn in_const(const self) { self.sort() }
}

fn <U> generic(const c: Buf<U>, b: Buf<U>) {
    c.sort()
    b.sort()
    b.far()
}

fn main() -> i32 {
    var b = Buf<i32>()
    const c = Buf<i32>()
    b.sort()
    c.sort()
    b.far()
    b.nothing()
    var m: usize = b.both()
    var k = c.both()
    var o: bool = b.own()
    var f = b.field
    var q = b?.size()
    b += 1
    var neg = -b
    var e = b[0]
    var i = 1 in b
    var x = b == 5
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="note ["
// CHECK: conversion_hop_errors.k:56:40: error [R025E]: no member named 'sort' in 'Buf'
// CHECK-NEXT: conversion_hop_errors.k:54:19: note [I900N]: 'View<T>' has 'sort', and this conversion to it takes 'self': it does not apply to a const 'Buf<T>'
// CHECK: conversion_hop_errors.k:60:7: error [R025E]: no member named 'sort' in 'Buf'
// CHECK-NEXT: conversion_hop_errors.k:54:19: note [I900N]: 'View<U>' has 'sort', and this conversion to it takes 'self': it does not apply to a const 'Buf<U>'
// CHECK: conversion_hop_errors.k:62:7: error [R025E]: no member named 'far' in 'Buf'
// CHECK: conversion_hop_errors.k:69:7: error [R025E]: no member named 'sort' in 'Buf'
// CHECK-NEXT: conversion_hop_errors.k:54:19: note [I900N]: 'View<i32>' has 'sort', and this conversion to it takes 'self': it does not apply to a const 'Buf<i32>'
// CHECK: conversion_hop_errors.k:70:7: error [R025E]: no member named 'far' in 'Buf'
// CHECK: conversion_hop_errors.k:71:7: error [R025E]: no member named 'nothing' in 'Buf'
// CHECK: conversion_hop_errors.k:73:15: error [R028E]: 'both' is ambiguous on 'Buf<i32>': it is no member of 'Buf', and its implicit conversions to 'View<const i32>' and to 'Other' both have one
// CHECK-NEXT: conversion_hop_errors.k:53:19: note [I900N]: through this conversion it is a member of 'View<const i32>'
// CHECK-NEXT: conversion_hop_errors.k:55:19: note [I900N]: through this conversion it is a member of 'Other'
// CHECK-NEXT: note [I900N]: convert the receiver with 'as' to say which is meant
// CHECK: conversion_hop_errors.k:75:15: error [R025E]: no member named 'field' in 'Buf'
// CHECK: conversion_hop_errors.k:76:16: error [R025E]: no member named 'size' in 'Buf'
// CHECK: conversion_hop_errors.k:77:5: error [SC066E]: no operator '+=' on 'Buf<i32>'
// CHECK: conversion_hop_errors.k:78:15: error [SC067E]: cannot negate a value of type 'Buf<i32>'
// CHECK: conversion_hop_errors.k:79:13: error [SC103E]: 'Buf<i32>' has no subscript operator
// CHECK: conversion_hop_errors.k:80:13: error [SC066E]: 'in' needs an 'op in' on 'Buf<i32>' taking a 'i32'
// CHECK: conversion_hop_errors.k:81:13: error [SC066E]: no 'op ==' on 'Buf<i32>'; a record compares only through its own operator
