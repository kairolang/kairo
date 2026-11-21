// A `for` over a call of a generator whose body is visible is written with
// no coroutine: the generator's push form (`bool g(params, __kairo_each<T>)`,
// written beside the coroutine from the same body) is called with the loop
// body, and no `Yield` local is made. The coroutine form stays where the
// push form cannot be used: a generator held in a variable, a `@no_inline`
// generator, a generator that takes a record by value, and a loop body that
// returns a record.

import std::io::println

struct Pair {
    var a: i64
    var b: i64
}

fn upto(n: i64) -> yield i64 {
    for var i: i64 = 0; i < n; i += 1 { yield i }
}

fn squares(n: i64) -> yield i64 {
    for v in upto(n) { yield v * v }
}

fn pairs(n: i64) -> yield Pair {
    for var i: i64 = 0; i < n; i += 1 { yield Pair { a: i, b: i * 3 } }
}

@no_inline fn kept(n: i64) -> yield i64 {
    for var i: i64 = 0; i < n; i += 1 { yield i }
}

fn letters(s: string) -> yield u8 {
    for var i: usize = 0; i < s.size(); i += 1 { yield s.data()[i] }
}

class Bag {
    var items: [i64; 4]
    fn Bag(self) {
        for var i: usize = 0; i < 4; i += 1 { self.items[i] = (i as i64) + 1 }
    }
    fn op in (const self) -> yield i64 {
        for var i: usize = 0; i < 4; i += 1 { yield self.items[i] }
    }
}

@no_inline fn sum_direct(n: i64) -> i64 {
    var sum: i64 = 0
    for v in upto(n) { sum += v }
    return sum
}

@no_inline fn sum_pipeline(n: i64) -> i64 {
    var sum: i64 = 0
    for v in squares(n) {
        if v == 9 { continue }
        if v > 50 { break }
        sum += v
    }
    return sum
}

@no_inline fn first_over(n: i64, limit: i64) -> i64 {
    for p in pairs(n) {
        if p.b > limit { return p.a }
    }
    return -1
}

@no_inline fn sum_bag(b: *Bag) -> i64 {
    var sum: i64 = 0
    for v in *b { sum += v }
    return sum
}

@no_inline fn sum_held(n: i64) -> i64 {
    var it  = upto(n)
    var sum: i64 = 0
    for v in it { sum += v }
    return sum
}

@no_inline fn sum_kept(n: i64) -> i64 {
    var sum: i64 = 0
    for v in kept(n) { sum += v }
    return sum
}

@no_inline fn sum_letters() -> i64 {
    var sum: i64 = 0
    for c in letters("abc") { sum += c }
    return sum
}

@no_inline fn find_pair(n: i64) -> Pair {
    for p in pairs(n) {
        if p.a == 2 { return p }
    }
    return Pair { a: -1, b: -1 }
}

fn main() -> i32 {
    var bag = Bag()
    println(f"direct: {sum_direct(5)}")
    println(f"pipeline: {sum_pipeline(100)}")
    println(f"first_over: {first_over(10, 10)} {first_over(2, 99)}")
    println(f"bag: {sum_bag(&bag)}")
    println(f"held: {sum_held(5)}")
    println(f"kept: {sum_kept(5)}")
    println(f"letters: {sum_letters()}")
    println(f"find: {find_pair(5).b} {find_pair(1).b}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      direct: 10
// OUT-NEXT: pipeline: 131
// OUT-NEXT: first_over: 4 -1
// OUT-NEXT: bag: 10
// OUT-NEXT: held: 10
// OUT-NEXT: kept: 10
// OUT-NEXT: letters: 294
// OUT-NEXT: find: 6 -1

// The push form is declared and defined beside each generator that has
// one, and a `yield` in it calls the loop body.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: inline bool upto(signed long n, ::__kairo_each<signed long> __kairo_f) noexcept;
// CXX: inline bool upto(signed long n, ::__kairo_each<signed long> __kairo_f) noexcept {
// CXX: if(!__kairo_f(i)) {
// CXX-NEXT: return false;
// CXX: return true;
// A loop inside a push form calls the inner form; its `yield` leaves
// through the flag.
// CXX: inline bool squares(signed long n, ::__kairo_each<signed long> __kairo_f) noexcept {
// CXX: bool __kairo_pfr = false;
// CXX: auto __kairo_pb0 =[&](auto & __kairo_pc0) noexcept->bool {
// CXX: ::push_form_ir::upto(n, ::__kairo_each<signed long> {
// CXX-NEXT: & ::__kairo_each<signed long>::template th<decltype(__kairo_pb0)>, __builtin_addressof(__kairo_pb0)
// CXX: if(__kairo_pfr) {
// CXX-NEXT: return __kairo_pfv;
// `kept` and `letters` have no push form.
// CXX-NOT: inline bool kept(
// CXX-NOT: inline bool letters(
// CXX-LABEL: sum_direct(signed long n) noexcept {
// CXX-NOT: Yield<
// CXX: ::push_form_ir::upto(n, ::__kairo_each<signed long> {
// CXX-NEXT: & ::__kairo_each<signed long>::template th<decltype(__kairo_pb0)>, __builtin_addressof(__kairo_pb0)
// CXX-LABEL: sum_pipeline(signed long n) noexcept {
// CXX-NOT: Yield<
// CXX: return true;
// CXX: return false;
// CXX: ::push_form_ir::squares(n, ::__kairo_each<signed long> {
// CXX-NEXT: & ::__kairo_each<signed long>::template th<decltype(__kairo_pb0)>, __builtin_addressof(__kairo_pb0)
// CXX-LABEL: first_over(signed long n, signed long limit) noexcept {
// CXX-NOT: Yield<
// CXX: bool __kairo_pfr = false;
// CXX: signed long __kairo_pfv;
// CXX: ::push_form_ir::pairs(n, ::__kairo_each< ::push_form_ir::Pair> {
// CXX: if(__kairo_pfr) {
// CXX-NEXT: return __kairo_pfv;
// CXX-LABEL: sum_bag(
// CXX-NOT: Yield<
// CXX: .__kairo_iter( ::__kairo_each<signed long> {
// CXX-LABEL: sum_held(signed long n) noexcept {
// CXX: while({{.*}}resume())
// CXX-LABEL: sum_kept(signed long n) noexcept {
// CXX: Yield<signed long> __kairo_it{{[0-9]+}} = ::push_form_ir::kept(n);
// CXX-LABEL: sum_letters() noexcept {
// CXX: Yield<unsigned char> __kairo_it{{[0-9]+}} = ::push_form_ir::letters(
// CXX-LABEL: find_pair(signed long n) noexcept {
// CXX: Yield<{{.*}}Pair> __kairo_it{{[0-9]+}} = ::push_form_ir::pairs(n);

// Optimized, a push-form loop is the generator's loop: no coroutine frame,
// no allocation, no indirect call.
// RUN: rm -rf %t.ll.d
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.ll.d
// RUN: %FileCheck %s --check-prefix=IR < %t.ll.d/push_form_ir.ll
// IR-LABEL: define {{.*}}10sum_direct{{.*}}(
// IR-NOT: call
// IR-LABEL: define {{.*}}12sum_pipeline{{.*}}(
// IR-NOT: call
// IR-LABEL: define {{.*}}10first_over{{.*}}(
// IR-NOT: call
// IR-LABEL: define {{.*}}7sum_bag{{.*}}(
// IR-NOT: call {{.*}}@_Zn
// IR-NOT: coro
// IR-LABEL: define {{.*}}8sum_held{{.*}}(
