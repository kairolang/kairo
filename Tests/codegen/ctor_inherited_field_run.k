// A constructor may assign a field of a base before it initializes its own
// fields that have no default (classes.mdx, Field initialization): the base
// is built first, so the write goes to the base's field, and each such own
// field is still constructed exactly once, in declaration order, and
// destroyed once. Covered: one and several fields with no default, a field
// with a default initializer, a base built by its initializer, a write on
// one branch only, a read of what was written, a generic base, a generic
// class, and a class that passes itself to its base.

var made: i32 = 0
var live: i32 = 0
var order: i32 = 0

class Q {                               // no default constructor
    pub var n: i32
    pub var at: i32
    fn Q(self, n: i32) {
        self.n = n
        made += 1
        live += 1
        order += 1
        self.at = order
    }
    @copy fn Q(self, const other: Q) {
        self.n = other.n
        self.at = other.at
        live += 1
    }
    fn op finally(self) { live -= 1 }
}

class Base {
    pub var ctx: i32 = 7
    pub var tag: i32 = 1
}

class One derives Base {
    pub var a: i32
    priv var dq: Q
    fn One(self, v: i32) {
        self.a = v
        self.ctx = v + 1                // a base's field, before dq exists
        self.dq = Q(2)
    }
    fn sum(self) -> i32 { return self.a + self.ctx + self.tag + self.dq.n }
}

class Many derives Base {
    pub var first: Q
    pub var mid: i32 = 5
    pub var second: Q
    pub var flag: bool
    fn Many(self, v: i32) {
        self.ctx = v
        self.second = Q(20)             // written first, built second
        self.tag = self.ctx + 1         // reads what this constructor wrote
        self.first = Q(10)
        self.flag = v > 0
        self.mid = self.mid + self.tag  // the object exists: an ordinary read
    }
}

class Arg {
    pub var ctx: i32
    fn Arg(self, c: i32) { self.ctx = c }
}

class Init derives Arg {
    pub var q: Q
    fn Init(self, v: i32) {
        Arg::Arg(self, v)
        if v > 1 { self.ctx = v * 100 } // on one path only: else the base's value stays
        self.q = Q(v)
    }
}

class <T> Holder {
    pub var item: T
    pub var count: i32 = 0
}

class Fixed derives Holder<i32> {
    pub var q: Q
    fn Fixed(self, x: i32) {
        self.item = x
        self.count = x + 1
        self.q = Q(x)
    }
}

class <T> Open derives Holder<T> {
    pub var q: Q
    fn Open(self, x: T) {
        self.item = x
        self.count = 2
        self.q = Q(3)
    }
}

class <T> Node {
    pub var ctx: i32 = 0
}

class Crtp derives Node<Crtp> {
    pub var q: Q
    fn Crtp(self, v: i32) {
        self.ctx = v
        self.q = Q(v)
    }
}

fn run() -> i32 {
    var o = One(1)
    if o.sum() != 1 + 2 + 1 + 2 { return 1 }

    var base = order
    var m = Many(3)
    if m.ctx != 3 || m.tag != 4 || m.mid != 9 || !m.flag { return 2 }
    if m.first.n != 10 || m.second.n != 20 { return 3 }
    // The right-hand sides run where they are written.
    if m.second.at != base + 1 || m.first.at != base + 2 { return 4 }

    var i1 = Init(1)
    var i2 = Init(2)
    if i1.ctx != 1 || i2.ctx != 200 || i1.q.n != 1 || i2.q.n != 2 { return 5 }

    var f = Fixed(4)
    if f.item != 4 || f.count != 5 || f.q.n != 4 { return 6 }

    var p = Open<i64>(6)
    if p.item != 6 || p.count != 2 || p.q.n != 3 { return 7 }

    var s = Crtp(8)
    if s.ctx != 8 || s.q.n != 8 { return 8 }

    // One Q built per field, each alive once.
    if made != 8 { return 9 }
    if live != 8 { return 10 }
    return 0
}

fn main() -> i32 {
    var r = run()
    if r != 0 { return r }
    if live != 0 { return 11 }          // each destroyed once
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// The base's field has no slot: the base exists when the pre-function runs,
// which assigns the field in the object.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}ctor_inherited_field_run.k
// IR-NOT: __kairo_slot{{ ?}}<{{ ?}}decltype{{ ?}}({{ ?}}{{.*}}::{{ ?}}ctx{{ ?}})
// IR:     __kairo_ctor_pre{{[0-9]+}}(
// IR:     this{{ ?}}->{{ ?}}ctx{{ ?}}={{ ?}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
