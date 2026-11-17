// `__builtin_is_trivially_relocatable<T>()` is true for a `@relocatable`
// record (a generic instance and one with `op finally` included), for an
// array of one, and for numbers, pointers and plain aggregates; it is
// false for a record with a `@move` or `@copy` constructor or a destructor
// of its own and no `@relocatable`, and a record that derives a relocatable
// one without the attribute does not inherit the answer. An unmarked
// aggregate or tuple of relocatable members and a `trivial_abi` C++ class
// are relocatable where C++ passes them as their bytes (the Itanium C++
// ABI, which the default target has). `__builtin_is_trivially_destructible`
// stays C++'s answer: `@relocatable` does not make a destructor trivial.
// Both pick a branch of an `eval if` in a generic body, per instance, and
// initialize an `eval` constant.
ffi "c++" import "trait.hh"
import std::io::println

@relocatable
class Handle {
    pub var a: usize
    pub fn Handle(self) { self.a = 1 }
    @move pub fn Handle(self, other: Self) { self.a = other.a }
    pub fn op finally(self) {}
}

@relocatable
class <T> Box {
    pub var p: *T?
    pub fn Box(self) { self.p = null }
    @move pub fn Box(self, other: Self) { self.p = other.p }
    pub fn op finally(self) {}
}

@relocatable
struct Pair { var h: Handle; var n: i32 }

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

class Child derives Handle {
    pub var m: Mv
    pub fn Child(self) {}
    @move pub fn Child(self, other: Self) = default
}

struct Plain { var a: i32; var b: *i32? }
struct HoldsHandle { var h: Handle; var n: i32 }

fn <T> reloc() -> i32 {
    eval if __builtin_is_trivially_relocatable<T>() {
        return 1
    } else {
        return 0
    }
}

fn <T> destr() -> i32 {
    eval if __builtin_is_trivially_destructible<T>() {
        return 1
    } else {
        return 0
    }
}

eval HANDLE_RELOC = __builtin_is_trivially_relocatable<Handle>()
eval BOX_RELOC    = __builtin_is_trivially_relocatable<Box<Mv>>()
eval MV_RELOC     = __builtin_is_trivially_relocatable<Mv>()
eval HANDLE_DESTR = __builtin_is_trivially_destructible<Handle>()
eval PLAIN_DESTR  = __builtin_is_trivially_destructible<Plain>()

fn main() -> i32 {
    println(f"reloc Handle {reloc<Handle>()} Box<i32> {reloc<Box<i32>>()} Box<Mv> {reloc<Box<Mv>>()} Pair {reloc<Pair>()} [Handle; 3] {reloc<[Handle; 3]>()}")
    println(f"reloc i32 {reloc<i32>()} f64 {reloc<f64>()} *i32 {reloc<*i32>()} *Mv? {reloc<*Mv?>()} Plain {reloc<Plain>()} [Plain; 2] {reloc<[Plain; 2]>()}")
    println(f"reloc Mv {reloc<Mv>()} Cp {reloc<Cp>()} Dt {reloc<Dt>()} [Mv; 2] {reloc<[Mv; 2]>()}")
    println(f"reloc Child {reloc<Child>()} HoldsHandle {reloc<HoldsHandle>()} (Handle, i32) {reloc<(Handle, i32)>()} CxxTrivialAbi {reloc<CxxTrivialAbi>()} CxxDtor {reloc<CxxDtor>()}")
    println(f"destr Handle {destr<Handle>()} Box<i32> {destr<Box<i32>>()} Dt {destr<Dt>()}")
    println(f"destr i32 {destr<i32>()} *i32 {destr<*i32>()} Plain {destr<Plain>()} Mv {destr<Mv>()} Cp {destr<Cp>()}")
    println(f"eval {HANDLE_RELOC} {BOX_RELOC} {MV_RELOC} {HANDLE_DESTR} {PLAIN_DESTR}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// The record names itself in a member alias the trait reads.
// RUN: %kairo %s --print-ir | %FileCheck %s --check-prefix=CXX
// CXX: class __attribute((trivial_abi)) Handle {
// CXX-NEXT: public: using __kairo_relocatable = Handle;
// CXX: struct __attribute((trivial_abi)) Pair {
// CXX-NEXT: using __kairo_relocatable = Pair;
// CXX: template<class T> class __attribute((trivial_abi)) Box {
// CXX-NEXT: public: using __kairo_relocatable = Box;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d/o2
// RUN: %t.o2.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      reloc Handle 1 Box<i32> 1 Box<Mv> 1 Pair 1 [Handle; 3] 1
// OUT-NEXT: reloc i32 1 f64 1 *i32 1 *Mv? 1 Plain 1 [Plain; 2] 1
// OUT-NEXT: reloc Mv 0 Cp 0 Dt 0 [Mv; 2] 0
// OUT-NEXT: reloc Child 0 HoldsHandle 1 (Handle, i32) 1 CxxTrivialAbi 1 CxxDtor 0
// OUT-NEXT: destr Handle 0 Box<i32> 0 Dt 0
// OUT-NEXT: destr i32 1 *i32 1 Plain 1 Mv 1 Cp 1
// OUT-NEXT: eval true true false false true
