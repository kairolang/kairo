// A generic pack function: `fn <...T> f(...xs: T)` is a C++ parameter pack,
// `T... xs`. A call spells the instance with one element per argument (a
// literal by its default type), the arguments go one per element, and an
// empty pack is an instance with no elements. `xs...` forwards the pack, a
// keyword-only parameter after it takes its default or its name, and
// `for x in xs` runs the body once per element: `continue`, `break` and
// `return` inside it keep their meaning.

fn <T> one(x: T) -> i32 { return 1 }

fn <...T> count(...args: T) -> i32 {
    var n = 0
    for arg in args {
        n += one(arg)
    }
    return n
}

fn <...T> third_times_ten(...args: T) -> i32 {
    var i = 0
    for a in args {
        i += 1
        if i == 2 { continue }
        if i == 3 { return i * 10 }
        if i == 9 { break }
    }
    return -1
}

fn <T, ...U> head(x: T, ...ys: U) -> T { return x }
fn <...T> scaled(...xs: T, scale: i32 = 2) -> i32 { return scale + count(xs...) }
fn <...T> none(...xs: T) -> i32 { return 5 }

fn main() -> i32 {
    var a = count(42, "hello", true)          // 3
    var h = head(7, 1.0, "x")                 // 7
    var b = scaled(1, 2, scale: 3)            // 5
    var d = scaled(1.5)                       // 3
    var c = none()                            // 5
    var t = third_times_ten(1, 2u8, 3.0, 4)   // 30
    var e = third_times_ten(1)                // -1
    return a + h + b + d + c + t + e          // 52
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<class T, class ... U> T head(T x, U ... ys) noexcept;
// CXX: template<class ... T> signed int count(T ... args) noexcept {
// CXX: (... &&[&]({{\[\[}}maybe_unused{{\]\]}} auto & arg)->bool {
// CXX: (args));
// CXX: template<class ... T> signed int scaled(T ... xs, signed int scale) noexcept {
// CXX-NEXT: return(scale + ::functions::count(xs ...));
// CXX: ::functions::count<signed int, ::builtin::string::string, bool>(42, {{.*}}, true);
// CXX: ::functions::none<>();
// CXX: template signed int( ::functions::count<signed int, ::builtin::string::string, bool>)(signed int, ::builtin::string::string, bool);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 52
