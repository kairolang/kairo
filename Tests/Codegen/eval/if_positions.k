// `eval if` in every position (EVAL.md §4): folded before name resolution,
// so an untaken branch may name what does not exist (`does_not_exist`,
// `NoSuchType`, `missing_thing`), and the taken branch's declarations are
// hoisted into the enclosing scope -- file scope (an `else if` chain), a
// module (nested `eval if`, a qualified condition), a class (a `var`
// becomes a field, an `eval` a static, a `fn` a method) and a function body
// (the branch's locals are the body's). A condition that names a generic
// parameter does not fold and is C++ `if constexpr`.

eval LEVEL = 2

eval if LEVEL > 5 {
    fn pick() -> i32 { return does_not_exist() }     // untaken: never resolved
} else if LEVEL == 2 {
    fn pick() -> i32 { return 20 }
    eval HOISTED = 3
} else {
    fn pick() -> i32 { return 30 }
}

module cfg {
    pub eval FAST = true
    eval if FAST && (LEVEL >= 1) {
        pub fn speed() -> i32 { return 100 }
        eval if !FAST { pub fn never() -> i32 { return no_such() } }
        else { pub eval INNER = 7 }
    } else {
        pub fn speed() -> i32 { return undeclared_too }
    }
}

class Box {
    pub var a: i32
    eval if cfg::FAST {
        pub var extra: i32
        pub eval K: i32 = 9
        pub fn get(self) -> i32 { return self.a + self.extra }
    } else {
        pub var other: NoSuchType
    }
}

fn <T> size_class(x: T) -> i32 {
    eval if sizeof T > 4 { return 8 } else { return 4 }
}

fn body() -> i32 {
    eval if HOISTED == 3 {
        var local = 5
        var other = 6
    } else {
        var local = missing_thing
    }
    return local + other
}

fn main() -> i32 {
    var big: i64 = 1
    var small: i32 = 1
    var b = Box()
    b.a = 1
    b.extra = 2
    return pick() + HOISTED + cfg::speed() + cfg::INNER + b.get() + Box::K + size_class(big) + size_class(small) + body()
    // 20 + 3 + 100 + 7 + 3 + 9 + 8 + 4 + 11 == 165
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}if_positions.k
// IR:     signed int extra {
// IR-NEXT: };
// IR:     signed int pick() noexcept {
// IR-NEXT:    return 20;
// IR:     template<class T> signed int size_class(T x) noexcept {
// IR-NEXT:    if constexpr(sizeof(T)> 4) {
// IR-NOT: does_not_exist

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 165
