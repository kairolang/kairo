// NULLABLE.md G2: the builtin `Nullable<T>` and `null_t` from the Kairo
// side, before any `T?` lowers to them (G3). Kairo code never names
// Nullable (type-system.md); Sema does not refuse the name yet, so this
// test does, to build instances of the lang item directly: a null one of
// a class with no default constructor holds nothing (no destructor runs),
// a present one destroys its payload exactly once, a move-only payload
// moves. The record a C++ host sees is pinned below: the ADT's own
// lifecycle members plus the constructors and primitives of the surface.

import std::io::println

class Widget {
    pub var id: i32
    pub fn Widget(self, id: i32) { self.id = id }
    @move fn Widget(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op delete(self) { if self.id != 0 { println(f"~Widget {self.id}") } }
}

fn present(id: i32) -> Nullable<Widget> { return Nullable<Widget>::Value { v: Widget(id) } }

fn relay(@move n: Nullable<Widget>) -> Nullable<Widget> { return n }

fn id_of(const n: Nullable<Widget>) -> i32 {
    return match n {
        case .Value(const v) => v.id
        case .Null           => -1
    }
}

fn main() -> i32 {
    var r = 0
    {
        var none: Nullable<Widget> = .Null
        if id_of(none) == -1 { r += 1 }
        var one = present(4)
        if id_of(one) == 4 { r += 2 }
        if id_of(relay(one)) == 4 { r += 4 }    // the move-only payload moves out; ~Widget 4 with the temporary
        println("scope end")
    }                                           // nothing: the one live Widget died with the relayed temporary
    var n: Nullable<i32> = .Null
    if n == Nullable<i32>::Null { r += 8 }
    println("done")
    return r                                    // 15
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}builtin{{/|\\}}module.k
// CXX:      struct null_t {
// CXX:      inline constexpr null_t null {
// CXX:      template<class T> struct Nullable {
// CXX:      Nullable(): __kairo_tag(__kairo_Tag::Null) {
// CXX:      Nullable( ::builtin::null_t): __kairo_tag(__kairo_Tag::Null) {
// CXX:      Nullable(const T & v) requires __kairo_copyable: __kairo_tag(__kairo_Tag::Value), __kairo_Value {
// CXX:      Nullable(T && v) requires __kairo_movable: __kairo_tag(__kairo_Tag::Value), __kairo_Value {
// CXX:      bool is_null() const {
// CXX:      T & __value() {
// CXX:      const T & __value() const {
// CXX:      bool operator ==(const Nullable & o) const requires requires(const T & a) {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out; test $? -eq 15
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      ~Widget 4
// OUT-NEXT: scope end
// OUT-NEXT: done
// OUT-EMPTY:
