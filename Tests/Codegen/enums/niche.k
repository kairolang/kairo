// Niche layout (spec ENUMLAYOUT §5): an ADT with one payload variant of one
// field, beside dataless variants, stores no tag when the field never holds
// some bit patterns and is trivially copied and destroyed. Each dataless
// variant is one such pattern: null for a pointer, `N + i` for a closed
// plain enum of N values (not `@open`: Codegen/enums/closed_enum_cast.k)
// or a tagged ADT's tag, and for a field that is itself niche-filled, the
// patterns past the ones it uses. So `(*Foo)?` is one
// pointer, `Color?` one byte (pattern 3), `(Color?)?` one byte (pattern 4),
// `((*Foo)?)?` falls back to a tag (its field's one pattern is taken), and
// `Inst?` is an Inst whose tag is 4.
//
// A generic ADT's instances are laid out by C++, from the constrained
// partial specialization beside the tagged primary. Sema predicts the
// choice: a match on an instance it can predict reads the field directly,
// one it cannot asks `__kairo_which()`, which both layouts answer. The
// sizes Sema predicts are pinned by the static_asserts beside each
// instantiation, so the program compiling is the size check, and the run
// checks them again through `sizeof`. A niche-filled `(*Foo)?` is
// standard-layout around one pointer, so it is passed and returned in a
// register exactly as `*Foo` is (SysV; checked in the object below).

enum Color derives u8 { Red, Green, Blue }

struct Foo { var a: i32 = 0; }

enum <T> Opt { Some { v: T }, None }

enum Inst { Const { value: i32 }, Neg { x: i32 }, Nop, Halt }

// Non-generic: laid out niche-filled in its only record.
enum MaybeFoo { Has { p: *Foo }, Empty }

fn ptr_some(o: Opt<*Foo>) -> bool = match o {
    case .Some => true
    case .None => false
}

fn color_of(o: Opt<Color>) -> i32 = match o {
    case .Some(var v) => v as u8
    case .None        => 9
}

fn nested(o: Opt<Color?>) -> i32 = match o {
    case .Some => 1
    case .None => 0
}

fn foo_a(m: MaybeFoo) -> i32 = match m {
    case .Has(var p) => p->a
    case .Empty      => -1
}

// Opaque: Box<i32>'s facts are its pattern's until instances get their own,
// so whether Opt<Box<i32>> is trivial -- and so whether the outer Opt is
// niche-filled -- is C++'s call; the match asks __kairo_which(), which both
// layouts answer. (A match or `==` on a generic ADT inside a generic body
// would be the other Opaque case, but those ICE today, ticketed.)
struct <T> Box { var v: T }

fn layered(o: Opt<Opt<Box<i32>>>) -> i32 = match o {
    case .Some => 1
    case .None        => 0
}

fn pass(p: *Foo?) -> *Foo? = p

fn main() -> i32 {
    var f = Foo{ a: 5 }
    var r = 0
    if (sizeof((*Foo)?) == 8) && (sizeof(Color?) == 1) && (sizeof((Color?)?) == 1) && (sizeof(((*Foo)?)?) == 16) { r += 1 }
    if (sizeof(Inst?) == sizeof(Inst)) && (sizeof(Opt<i32>) == 8) && (sizeof(MaybeFoo) == 8) { r += 2 }
    if ptr_some(Opt<*Foo>::Some { v: &f }) && (!ptr_some(Opt<*Foo>::None)) { r += 4 }
    if (color_of(Opt<Color>::Some { v: .Blue }) == 2) && (color_of(.None) == 9) { r += 8 }
    var c: Color? = Color::Red
    var n: Color? = null
    if (nested(Opt<Color?>::Some { v: c }) == 1) && (nested(Opt<Color?>::Some { v: n }) == 1) && (nested(.None) == 0) { r += 16 }
    if (foo_a(MaybeFoo::Has { p: &f }) == 5) && (foo_a(.Empty) == -1) { r += 32 }
    var bx = Opt<Box<i32>>::Some { v: Box<i32>{ v: 3 } }
    if (layered(Opt<Opt<Box<i32>>>::Some { v: bx }) == 1) && (layered(.None) == 0) { r += 64 }
    var *q? = pass(&f)
    var *z? = pass(null)
    var i: Inst? = Inst::Halt
    if q? && (!z?) && i? && (Opt<*Foo>::None == Opt<*Foo>::None) && (Opt<*Foo>::Some { v: &f } != Opt<*Foo>::None) { r += 128 }
    return r                                    // 255
}

// --- lit wiring -----------------------------------------------------------
// The nested nullables are S055W ("rarely what you want"): wanted here.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// DIAG-NOT: warning [{{[^S]|S[^0]|S0[^5]|S05[^5]}}

// The trait, a plain enum's answer to it after the enum, the tagged
// primary's own answer, and the niche-filled partial specialization.
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}niche.k
// CXX:       template<class T> struct __kairo_niche<T*> {
// CXX-NEXT:  static constexpr unsigned long count = 1;
// CXX:       template<> struct __kairo_niche<::{{.*}}::Color> {
// CXX-NEXT:  static constexpr unsigned long count = 253;
// CXX:       template<class T> struct Opt {
// CXX-NEXT:  enum class __kairo_Tag : unsigned char {
// CXX:       __kairo_Tag __kairo_which() const noexcept {
// CXX-NEXT:  return __kairo_tag;
// CXX:       static constexpr unsigned long __kairo_niche_count = 254;
// CXX:       template<class T> requires(::__kairo_niche<T>::count >= 1&& __is_trivially_copyable(T)&& __is_trivially_destructible(T)) struct Opt<T> {
// CXX-NOT:   __kairo_tag
// CXX:       __kairo_Some_t __kairo_Some;
// CXX-NOT:   __kairo_tag
// CXX:       Opt(::__kairo_vt<0>, T v) noexcept : __kairo_Some {
// CXX:       Opt(::__kairo_vt<1>) noexcept : __kairo_Some {
// CXX-NEXT:  ::__kairo_niche<T>::pattern(0) }
// CXX:       return::__kairo_niche<T>::test(__kairo_Some . v, 0) ? __kairo_Tag::None : __kairo_Tag::Some;
// CXX:       static constexpr unsigned long __kairo_niche_count =::__kairo_niche<T>::count - 1;
// CXX:       struct Inst {
// CXX:       static constexpr unsigned long __kairo_niche_count = 252;
// CXX:       struct MaybeFoo {
// CXX-NOT:   __kairo_tag
// CXX:       __kairo_Has_t __kairo_Has;
// CXX:       MaybeFoo(::__kairo_vt<1>) noexcept : __kairo_Has {
// CXX-NEXT:  ::__kairo_niche<::{{.*}}::Foo*>::pattern(0) }
// CXX:       static_assert(sizeof(MaybeFoo) == sizeof(MaybeFoo::__kairo_Has_t)&& __is_standard_layout(MaybeFoo));

// The reads: a concrete instance's field directly, an unpredictable one's
// through __kairo_which(), and the sizes pinned beside each instantiation.
// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}niche.k
// IR:       bool ptr_some(
// IR:       if(__kairo_m0_s.__kairo_Some.v != nullptr) {
// IR:       signed int color_of(
// IR:       if(__kairo_m0_s.__kairo_Some.v != static_cast< ::{{.*}}::Color>(3)) {
// IR:       signed int nested(
// IR:       if(__kairo_m0_s.__kairo_Some.v.__kairo_Value.v != static_cast< ::{{.*}}::Color>(4)) {
// IR:       signed int foo_a(
// IR:       if(__kairo_m0_s.__kairo_Has.p != nullptr) {
// IR:       signed int layered(
// IR:       switch(static_cast<unsigned int>(__kairo_m0_s.__kairo_which())) {
// IR:       int main()
// IR-DAG:   static_assert(sizeof({{ ?}}::builtin::Nullable< ::{{.*}}::Foo *>) == 8);
// IR-DAG:   static_assert(sizeof({{ ?}}::builtin::Nullable< ::{{.*}}::Color>) == 1);
// IR-DAG:   static_assert(sizeof({{ ?}}::builtin::Nullable< ::builtin::Nullable< ::{{.*}}::Color>>) == 1);
// IR-DAG:   static_assert(sizeof({{ ?}}::builtin::Nullable< ::builtin::Nullable< ::{{.*}}::Foo *>>) == 16);
// IR-DAG:   static_assert(sizeof({{ ?}}::builtin::Nullable< ::{{.*}}::Inst>) == 8);
// IR-DAG:   static_assert(sizeof({{ ?}}::{{.*}}::Opt<signed int>) == 8);
// IR-DAG:   static_assert(sizeof({{ ?}}::builtin::Nullable< ::{{.*}}::Foo *>) == sizeof({{ ?}}::builtin::Nullable< ::{{.*}}::Foo *>::__kairo_Value_t) && __is_standard_layout({{ ?}}::builtin::Nullable< ::{{.*}}::Foo *>));

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 255
// `pass` takes and returns its nullable pointer in registers, as a pointer.
// RUN: %kairo %s -c -O2 --cache-dir %t.o2
// RUN: %objdump -d --no-show-raw-insn %t.o2/niche.o | awk '/<[^>]*4pass[^>]*>:/,/^$/' | grep -v nop > %t.pass.s
// RUN: grep -q ret %t.pass.s
// RUN: { ! grep -qE 'call|push|pop|\(%' %t.pass.s; }
