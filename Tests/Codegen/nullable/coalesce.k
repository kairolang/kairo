// G8 (Compiler/Sema/NULLABLE.md 2.4): `x ?? y` is `if x? => x else y`,
// built by CoalesceLowering and run. Covered: values and pointers, a place
// read twice (`a`, `x.cache`, `self.cache`) with no temporary; a call on
// the left bound ONCE (its side effects counted) and its value MOVED out of
// the temporary; right-associative chains whose middle is a call; a
// nullable fallback (the result stays `T?`); `(i32?)? ?? i32?` is `i32?`;
// `??` in an `if` and a `while` condition (re-evaluated per iteration); a
// record with a destructor, whose fallback is constructed only on null and
// whose value is destroyed exactly once; a generic `T? ?? T`. Each line
// prints, so a wrong value shows which case broke.

import std::io::println

class Widget {
    pub var id: i32
    pub fn Widget(self, id: i32) { self.id = id; println(f"+Widget {id}") }
    @move fn Widget(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op delete(self) { if self.id != 0 { println(f"~Widget {self.id}") } }
}

class Box {
    pub var cache: i32? = null
    pub fn Box(self) { }
    pub fn get(self) -> i32 { return self.cache ?? -1 }
}

var calls = 0

fn find(k: i32) -> i32? { calls += 1; if k > 0 { return k } return null }
fn widget(k: i32) -> Widget? { if k > 0 { return Widget(k) } return null }
fn nested(k: i32) -> (i32?)? {
    if k > 1 { var v: i32? = k; return v }
    if k == 1 { var n: i32? = null; return n }
    return null
}
fn <T> or_(t: T?, d: T) -> T { return t ?? d }

fn main() -> i32 {
    var a: i32? = 4
    var b: i32? = null
    println(f"value: {a ?? 0} {b ?? 7} {a}")

    var n = 3
    var m = 9
    var p: (*i32)? = &n
    var q: (*i32)? = &null
    println(f"pointer: {*(p ?? &m)} {*(q ?? &m)}")

    calls = 0
    var c = find(5) ?? 100
    var d = find(-1) ?? 100
    println(f"once: {c} {d} calls={calls}")

    calls = 0
    println(f"chain: {b ?? find(-2) ?? 3} {b ?? find(6) ?? 3} {a ?? find(1) ?? 3} calls={calls}")

    var e? = b ?? find(-3)
    var f? = b ?? find(8)
    println(f"nullable: {e?} {f ?? 0}")

    var nn? = nested(5) ?? b
    var nb? = nested(1) ?? a
    var nz? = nested(0) ?? a
    println(f"nested: {nn ?? 0} {nb?} {nz ?? 0}")

    var x = Box()
    println(f"field: {x.cache ?? 11} {x.get()}")
    x.cache = 12
    println(f"field: {x.cache ?? 11} {x.get()}")

    if (b ?? 2) > 1 { println("cond: yes") }
    var i = 0
    calls = 0
    while (find(-1) ?? i) < 2 { i += 1 }
    println(f"loop: {i} calls={calls}")

    {
        var w = widget(1) ?? Widget(9)
        println(f"record: {w.id}")
    }
    {
        var w = widget(0) ?? Widget(9)
        println(f"record: {w.id}")
    }
    var g: i32? = null
    println(f"generic: {or_(g, 3)} {or_(a, 3)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: error
// DIAG:     warning [S055W]: nested nullable
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      return((!this->cache.is_null()) ? this->cache.__value():(- 1));
// CXX:      return((!t.is_null()) ? t.__value(): d);
// CXX:      ((!a.is_null()) ? a.__value(): 0);
// CXX:      (*((!p.is_null()) ? p.__value():(& m)));
// CXX:      ::builtin::Nullable<signed int> __kairo_coal0 ={{ ?}}::{{.*}}find(5);
// CXX-NEXT: ((!__kairo_coal0.is_null()) ? static_cast<signed int &&>(__kairo_coal0.__value()): 100);
// CXX:      static_cast<{{ ?}}::builtin::Nullable<signed int> &&>(__kairo_coal{{[0-9]+}}.__value()): b);
// CXX:      ((!x.cache.is_null()) ? x.cache.__value(): 11);
// CXX:      static_cast<{{ ?}}::{{.*}}Widget &&>(__kairo_coal{{[0-9]+}}.__value()):{{ ?}}::{{.*}}Widget(9));
// CXX-NOT:  ??

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      value: 4 7 4
// OUT-NEXT: pointer: 3 9
// OUT-NEXT: once: 5 100 calls=2
// OUT-NEXT: chain: 3 6 4 calls=2
// OUT-NEXT: nullable: false 8
// OUT-NEXT: nested: 5 false 4
// OUT-NEXT: field: 11 -1
// OUT-NEXT: field: 12 12
// OUT-NEXT: cond: yes
// OUT-NEXT: loop: 2 calls=3
// OUT-NEXT: +Widget 1
// OUT-NEXT: record: 1
// OUT-NEXT: ~Widget 1
// OUT-NEXT: +Widget 9
// OUT-NEXT: record: 9
// OUT-NEXT: ~Widget 9
// OUT-NEXT: generic: 3 4
