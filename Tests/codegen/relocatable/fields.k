// `@relocatable` is clang's `trivial_abi`, which clang drops, with a warning
// only, from a record that has a base or a field it cannot pass as bytes.
// Kairo makes that an error at the attribute (SC356E), naming the part and
// why, and accepts exactly the records clang keeps the attribute on: every
// record of the accepted half compiles with no "'trivial_abi' cannot be
// applied" warning from clang.
ffi "c++" import "fields.hh"

@relocatable
class H {
    pub var a: usize
    pub fn H(self) { self.a = 1 }
    @move pub fn H(self, other: Self) { self.a = other.a }
    pub fn op finally(self) {}
}

@relocatable
class <T> B {
    pub var p: *T?
    pub fn B(self) { self.p = null }
    @move pub fn B(self, other: Self) { self.p = other.p }
    pub fn op finally(self) {}
}

class Mv {
    pub var a: usize
    pub fn Mv(self) { self.a = 1 }
    @move pub fn Mv(self, other: Self) { self.a = other.a }
}

class Cp {
    pub var a: usize
    pub fn Cp(self) { self.a = 1 }
    @copy pub fn Cp(self, const other: Self) { self.a = other.a }
}

class Dt {
    pub var a: usize
    pub fn Dt(self) { self.a = 1 }
    @move pub fn Dt(self, other: Self) = default
    pub fn op finally(self) {}
}

class DefMv {
    pub var a: usize
    pub fn DefMv(self) { self.a = 1 }
    @move pub fn DefMv(self, other: Self) = default
}

struct Plain { var a: i32; var b: *i32? }
struct HoldsH { var h: H }
struct HoldsMv { var m: Mv }
union TwoPtrs { var ro: *const u8?; var rw: *u8? }
enum Color { Red, Green }
enum Shape { Dot { v: i32 }, Line { w: f64 } }
enum Owner { One { h: H }, None { v: i32 } }
class Base { pub var a: i32 = 0 }
class BaseDt {
    pub var a: i32 = 0
    @move pub fn BaseDt(self, other: Self) = default
    pub fn BaseDt(self) {}
    pub fn op finally(self) {}
}

// --- accepted --------------------------------------------------------------

@relocatable
class Scalars {
    pub var a: i32
    pub var p: *i32
    pub var q: *i32?
    pub var u: unsafe *i32
    pub var c: Color
    pub var f: unsafe fn(i32) -> i32
    pub var arr: [i32; 4]
    pub var s: [i32;]
    @move pub fn Scalars(self, other: Self) = default
    pub fn op finally(self) {}
}

@relocatable
class Records {
    pub var plain: Plain
    pub var u: TwoPtrs
    pub var shape: Shape
    pub var h: H
    pub var hs: [H; 2]
    pub var b: B<i32>
    pub var bm: B<Mv>
    pub var d: DefMv
    pub var hh: HoldsH
    pub var t: (i32, f64)
    pub var th: (H, i32)
    pub var oi: i32?
    pub var ol: Plain?
    @move pub fn Records(self, other: Self) = default
    pub fn op finally(self) {}
}

@relocatable
class Foreign {
    pub var a: CxxTrivial
    pub var b: CxxAssign
    pub var c: CxxTrivialAbi
    pub var d: CxxMoveOnly
    @move pub fn Foreign(self, other: Self) = default
    pub fn op finally(self) {}
}

@relocatable
class DerivesPlain derives Base {
    pub var z: i32 = 0
}

@relocatable
class DerivesH derives H {
    pub var z: i32 = 0
    pub fn DerivesH(self) {}
    @move pub fn DerivesH(self, other: Self) = default
    pub fn op finally(self) {}
}

@relocatable
struct PlainStruct { var h: H; var n: i32 }

// The shapes the builtin string and vector have: a nested union of two
// pointers beside a word, and a pointer to the element beside a length.
@relocatable
class Str {
    priv union Ptr {
        var ro: *const u8?
        var rw: *u8?
    }

    priv var p:    Self::Ptr
    priv var meta: usize

    pub fn Str(self) { self.meta = 0 }
    @move pub fn Str(self, other: Self) {
        self.p     = other.p
        self.meta  = other.meta
        other.meta = 0
    }

    pub fn op finally(self) {}
}

@relocatable
class <T> Vec {
    priv var buf: *T?
    priv var len: usize

    pub fn Vec(self) {
        self.buf = null
        self.len = 0
    }

    @move pub fn Vec(self, other: Self) {
        self.buf  = other.buf
        self.len  = other.len
        other.len = 0
    }

    pub fn op finally(self) {}
}

// A field of the parameter's type is each instance's to answer.
@relocatable
class <T> Wrap {
    pub var v: T
    pub fn Wrap(self, v: T) { self.v = v }
    @move pub fn Wrap(self, other: Self) = default
    pub fn op finally(self) {}
}

fn use_accepted() -> usize {
    var s  = Str()
    var v  = Vec<Mv>()
    var vs = Vec<Str>()
    var w  = Wrap<i32>(3)
    var wh = Wrap<H>(H())
    return wh.v.a
}

// --- rejected --------------------------------------------------------------

eval if defined!(BAD) {
    // ERR: [[@LINE+1]]:5: error [SC356E]: '@relocatable' cannot be applied to 'BadMv': its field 'f' of type 'Mv' is not relocatable
    @relocatable
    class BadMv {
        // ERR: [[@LINE+1]]:{{[0-9]+}}: note [SC356N]: 'Mv' is not relocatable: it has a transfer constructor with a body and is not marked '@relocatable'
        pub var f: Mv
        @move pub fn BadMv(self, other: Self) = default
        pub fn op finally(self) {}
    }

    // ERR: [[@LINE+1]]:5: error [SC356E]: '@relocatable' cannot be applied to 'BadCp': its field 'f' of type 'Cp' is not relocatable
    @relocatable
    class BadCp {
        pub var f: Cp
        @copy pub fn BadCp(self, const other: Self) = default
        pub fn op finally(self) {}
    }

    // ERR: [[@LINE+1]]:5: error [SC356E]: '@relocatable' cannot be applied to 'BadDt': its field 'f' of type 'Dt' is not relocatable
    @relocatable
    class BadDt {
        // ERR: [[@LINE+1]]:{{[0-9]+}}: note [SC356N]: 'Dt' is not relocatable: it has a destructor and is not marked '@relocatable'
        pub var f: Dt
        @move pub fn BadDt(self, other: Self) = default
        pub fn op finally(self) {}
    }

    // Two fields, two errors, each at the attribute.
    // ERR: [[@LINE+1]]:5: error [SC356E]: '@relocatable' cannot be applied to 'BadTwo': its field 'a' of type 'HoldsMv' is not relocatable
    @relocatable
    struct BadTwo {
        // ERR: [[@LINE+1]]:{{[0-9]+}}: note [SC356N]: 'HoldsMv' is not relocatable: its field 'm' is not relocatable
        var a: HoldsMv
        // ERR: [[@LINE-4]]:5: error [SC356E]: '@relocatable' cannot be applied to 'BadTwo': its field 'b' of type '[Mv; 2]' is not relocatable
        var b: [Mv; 2]
    }

    // ERR: [[@LINE+1]]:5: error [SC356E]: '@relocatable' cannot be applied to 'BadOwner': its field 'f' of type 'Owner' is not relocatable
    @relocatable
    class BadOwner {
        // ERR: [[@LINE+1]]:{{[0-9]+}}: note [SC356N]: 'Owner' is not relocatable: an enum with payloads is relocatable only when every payload is trivially copyable and trivially destroyed
        pub var f: Owner
        @move pub fn BadOwner(self, other: Self) = default
        pub fn op finally(self) {}
    }

    // ERR: [[@LINE+1]]:5: error [SC356E]: '@relocatable' cannot be applied to 'BadOpt': its field 'f' of type 'H?' is not relocatable
    @relocatable
    class BadOpt {
        // ERR: [[@LINE+1]]:{{[0-9]+}}: note [SC356N]: 'H?' is not relocatable: a nullable value is relocatable only when the value is trivially copyable and trivially destroyed
        pub var f: H?
        @move pub fn BadOpt(self, other: Self) = default
        pub fn op finally(self) {}
    }

    // ERR: [[@LINE+1]]:5: error [SC356E]: '@relocatable' cannot be applied to 'BadFn': its field 'f' of type 'fn (i32) -> i32' is not relocatable
    @relocatable
    class BadFn {
        // ERR: [[@LINE+1]]:{{[0-9]+}}: note [SC356N]: 'fn (i32) -> i32' is not relocatable: a 'fn' value owns the closure it holds
        pub var f: fn(i32) -> i32
        @move pub fn BadFn(self, other: Self) = default
        pub fn op finally(self) {}
    }

    // string is itself @relocatable, so a class holding one may be too.
    // ERR-NOT: StringOk
    @relocatable
    class StringOk {
        pub var f: string
        @move pub fn StringOk(self, other: Self) = default
        pub fn op finally(self) {}
    }

    // ERR: [[@LINE+1]]:5: error [SC356E]: '@relocatable' cannot be applied to 'BadCxx': its field 'f' of type 'CxxDtor' is not relocatable
    @relocatable
    class BadCxx {
        // ERR: [[@LINE+1]]:{{[0-9]+}}: note [SC356N]: 'CxxDtor' is not relocatable: it is a C++ type with a non-trivial copy constructor, move constructor or destructor
        pub var f: CxxDtor
        @move pub fn BadCxx(self, other: Self) = default
        pub fn op finally(self) {}
    }

    // ERR: [[@LINE+1]]:5: error [SC356E]: '@relocatable' cannot be applied to 'BadBase': its base 'BaseDt' is not relocatable
    @relocatable
    // ERR: [[@LINE+1]]:{{[0-9]+}}: note [SC356N]: 'BaseDt' is not relocatable: it has a destructor and is not marked '@relocatable'
    class BadBase derives BaseDt {
        pub var z: i32 = 0
        pub fn BadBase(self) {}
        @move pub fn BadBase(self, other: Self) = default
        pub fn op finally(self) {}
    }

    // ERR: [[@LINE+1]]:5: error [SC356E]: '@relocatable' cannot be applied to 'BadVirtual': it is polymorphic, and its bytes hold the address of its virtual table
    @relocatable
    class BadVirtual {
        pub var z: i32 = 0
        pub virtual fn f(self) -> i32 { return 1 }
        @move pub fn BadVirtual(self, other: Self) = default
    }

    // ERR: [[@LINE+1]]:5: error [SC356E]: '@relocatable' cannot be applied to 'BadDeleted': its transfer constructors are deleted, so nothing moves it
    @relocatable
    class BadDeleted {
        pub var z: i32 = 0
        @copy pub fn BadDeleted(self, const other: Self) = delete
    }

    fn use_rejected() -> usize {
        // ERR: [[@LINE+1]]:{{[0-9]+}}: error [SC356E]: '@relocatable' cannot be applied to 'Wrap<Mv>': its field 'v' of type 'Mv' is not relocatable
        var w = Wrap<Mv>(Mv())
        return w.v.a
    }
}

fn main() -> i32 {
    return if (use_accepted() == 1) => (0) else => 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -DBAD 2>&1 || true; } | %FileCheck %s --check-prefix=ERR
// RUN: %kairo %s --type-check-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// RUN: %t.exe
// OK-NOT: error [
// OK-NOT: warning [
