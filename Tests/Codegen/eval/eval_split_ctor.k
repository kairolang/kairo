// An eval constructor that initializes a const field (EVAL.md 7, CODEGEN.md
// §6 split): CtorInitLowering cuts it into S_pre / S_post, and EmitIR
// writes the pre-function, the slot constructor and the public one. All
// three are `consteval` with it, in the class and at the definitions (a
// definition without it is clang's "non-constexpr declaration follows
// consteval declaration"), and the slots it fills live inside one constant
// evaluation: C++23 has no placement new there, so a slot holds its value
// in a transient heap box (`if consteval`) that it frees before the
// evaluation ends. A carried local, a const field of a class type that has
// a const field itself (its one initialization constructs it, so it is no
// assignment), a const array built whole, an array with no default built
// element by element, a generic eval class, and the same constructor
// called at run time with constant arguments.

class Tag {
    pub const id: i32
    pub var n: i32 = 1
    eval fn Tag(self, id: i32) {
        var twice = id * 2               // carried into S_post through a slot
        self.id = twice
        self.n += twice
    }
    eval fn get(const self) -> i32 { return self.id + self.n }
}

class Pair {
    pub const left: Tag
    pub const row: [i32; 2]
    eval fn Pair(self, a: i32) {
        self.left = Tag(a)
        self.row = [a, a + 1]
    }
}

class Flags {
    pub var on: [bool; 2]
    eval fn Flags(self, a: i32) { self.on[0] = a > 1  self.on[1] = a > 5 }
}

class <T> Cell {
    pub const v: T
    eval fn Cell(self, v: T) { self.v = v }
}

eval T = Tag(7)                          // id 14, n 15
eval G = T.get()                         // 29
eval P = Pair(3)                         // left.id 6, row [3, 4]
eval F = Flags(2)                        // [true, false]
eval C = Cell<i64>(40)

fn main() -> i32 {
    var t = Tag(2)                       // run time, constant argument: id 4
    var r = G + t.id                     // 33
    r += P.left.id + P.row[0] + P.row[1] // 46
    r += (C.v as i32)                    // 86
    if F.on[0] { r += 100 }              // 186
    if F.on[1] { r += 1000 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}eval_split_ctor.k
// IR:      consteval Tag(signed int id) noexcept;
// IR:      static consteval auto __kairo_ctor_pre0(
// IR-NEXT: consteval Tag(__kairo_ci0 & __kairo_s,
// IR:      consteval auto Tag::__kairo_ctor_pre0(
// IR:      consteval Tag::Tag(__kairo_ci0 & __kairo_s,
// IR:      consteval Tag::Tag(signed int id) noexcept: Tag(
// IR:      template<class T> consteval Cell<T>::Cell(T v) noexcept: Cell(

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 186
