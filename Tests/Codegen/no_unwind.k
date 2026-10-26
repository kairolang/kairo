// Which Kairo functions are `noexcept` in C++. By default every one is: a
// free function, a method, a closure's call operator and `__kairo_fn`'s
// call path, on the declaration and the definition alike (C++ requires
// them to agree). `@unwind` takes it off one function, so a C++ exception
// may pass through that frame; `@no_unwind` keeps it on even under
// -funwind, which takes it off everything else. Both on one function is
// SC001E. A C++ declaration imported with `ffi` is C++'s, never touched.
// The run tests are Tests/Codegen/exceptions/.

class C {
    pub var n: i32
    @no_unwind pub fn get(const self) -> i32 { return self.n }
    @unwind pub fn put(self, v: i32) { self.n = v }
    pub fn plain(const self) -> i32 { return self.n }
}

@unwind fn passes(a: i32) -> i32 { return a }
@no_unwind fn stops(a: i32) -> i32 { return a }
fn dflt(a: i32) -> i32 { return a }

fn main() -> i32 {
    var f = fn (x: i32) -> i32 { return x + 1 }
    var c = C { n: 1 }
    c.put(1)
    return f(dflt(passes(stops(c.get())))) + c.plain()   // 2 + 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=DECL
// DECL: R operator()(A ... a) const noexcept {
// DECL: signed int get() const noexcept;
// DECL-NEXT: void put(signed int v);
// DECL-NEXT: signed int plain() const noexcept;
// DECL: signed int passes(signed int a);
// DECL: signed int stops(signed int a) noexcept;
// DECL: signed int dflt(signed int a) noexcept;

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=DEF
// DEF: signed int C::get() const noexcept {
// DEF: void C::put(signed int v) {
// DEF: signed int C::plain() const noexcept {
// DEF: signed int passes(signed int a) {
// DEF: signed int stops(signed int a) noexcept {
// DEF: signed int dflt(signed int a) noexcept {
// DEF: int main() noexcept {
// DEF-NEXT: {{.*}}(+[](signed int x) noexcept->signed int {

// -funwind: only `@no_unwind` stays noexcept.
// RUN: { %kairo %s -funwind --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=UDECL
// UDECL: R operator()(A ... a) const {
// UDECL: signed int get() const noexcept;
// UDECL-NEXT: void put(signed int v);
// UDECL-NEXT: signed int plain() const;
// UDECL: signed int passes(signed int a);
// UDECL: signed int stops(signed int a) noexcept;
// UDECL: signed int dflt(signed int a);
// RUN: { %kairo %s -funwind --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=UDEF
// UDEF: int main() {
// UDEF-NEXT: {{.*}}(+[](signed int x)->signed int {

// Both attributes on one function.
// RUN: printf '@unwind @no_unwind fn both() -> i32 { return 0 }\nfn main() -> i32 { return both() }\n' > %t.both.k
// RUN: { %kairo %t.both.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=BOTH
// BOTH: :1:20: error [SC001E]: 'both' is marked both '@unwind' and '@no_unwind'
// BOTH-NEXT: :1:20: note [SC001N]: '@no_unwind' is here; it wins: the function is 'noexcept'

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 3
