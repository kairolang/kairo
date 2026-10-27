// The Panic lang item (PANIC.md §1.1, §1.1a, §1.3, §1.4), reached through
// the --test-panic-type hook until PanicLowering forms it: tags are type ids
// (Ok is 0), the set is one type whatever order it is written in, word 0 is
// the u32 tag and the u32 site, the payloads start at max(8, their
// alignment), and a `void` Ok holds an empty struct. The C++ reads the ids
// Sema computed, so a construct, copy and match round-trip proves they agree.

struct A { var x: i32 }
struct B { var y: i64 }
struct W { var a: i64; var b: i64 }

fn mk(n: i32) -> Panic<i32, B, A> {
    if n == 0 { return Panic<i32, B, A>::Ok { value: 7 } }
    if n == 1 { return Panic<i32, A, B>::Err { error: A { x: 11 } } }
    return Panic<i32, B, A>::Err { error: B { y: 22 } }
}

fn read(p: Panic<i32, A, B, A>) -> i64 {
    match p {
        case .Ok(var value) { return value }
        case .Err(var error: A) { return error.x }
        case .Err(var error: B) { return error.y }
    }
}

fn void_ok(fail: bool) -> Panic<void, A> {
    if fail { return Panic<void, A>::Err { error: A { x: 5 } } }
    return Panic<void, A>::Err { error: A { x: 6 } }
}

fn wide() -> Panic<i32, W> { return Panic<i32, W>::Err { error: W { a: 1, b: 2 } } }
fn aligned() -> Panic<i32, i128> { return Panic<i32, i128>::Ok { value: 3 } }

fn main() -> i32 {
    var a = mk(0)
    var b = mk(1)
    var c = b
    c = mk(2)
    if read(a) != 7 { return 1 }
    if read(b) != 11 { return 2 }
    if read(c) != 22 { return 3 }
    match void_ok(true) {
        case .Ok { return 4 }
        case .Err(var error: A) { if error.x != 5 { return 5 } }
    }
    match wide() {
        case .Ok(var value) { return 6 }
        case .Err(var error: W) { if error.b != 2 { return 7 } }
    }
    match aligned() {
        case .Ok(var value) { if value != 3 { return 8 } }
        case .Err(var error: i128) { return 9 }
    }
    if __builtin_type_id<A>() == __builtin_type_id<B>() { return 10 }
    var s1 = __builtin_panic_site()
    var s2 = __builtin_panic_site()
    if (s1 == 0) || (s1 == s2) { return 11 }
    return 42
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --test-panic-type --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// The register cliff: past 16 bytes, at the set's formation, naming the
// widest payload. 16 bytes exactly is quiet.
// DIAG-NOT: error
// DIAG: lang_item.k:31:14: remark [OPT001R]: 'Panic<i32, W>' is 24 bytes, so a function returning it returns through memory, not in two registers; its widest payload, 'W', is 16 bytes
// DIAG: lang_item.k:32:17: remark [OPT001R]: 'Panic<i32, i128>' is 32 bytes, {{.*}}; its widest payload, 'i128', is 16 bytes
// DIAG-NOT: remark

// One instance for `<i32, B, A>`, `<i32, A, B>` and `<i32, A, B, A>`; the
// layout Sema predicts (the C++ static_asserts it), the payload offset at
// the union's alignment, and each element's id.
// RUN: { %kairo %s --test-panic-type --type-check-only --print-panic-sets 2>/dev/null || true; } | %FileCheck %s --check-prefix=SETS
// SETS: -- panic sets --
// SETS-DAG: Panic<signed int, ::{{.*}}::{{[AB]}}, ::{{.*}}::{{[AB]}}>: size 16, payload offset 8
// SETS-DAG: Panic<signed int, ::{{.*}}::W>: size 24, payload offset 8
// SETS-DAG: Panic<signed int, __int128>: size 32, payload offset 16
// SETS-DAG: Panic<void, ::{{.*}}::A>: size 16, payload offset 8
// SETS-DAG: ::{{.*}}::A = 0x[[AID:[0-9a-f]+]]
// SETS-DAG: ::{{.*}}::B = 0x[[BID:[0-9a-f]+]]

// RUN: { %kairo %s --test-panic-type --print-panic-sets --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=CXX
// CXX: -- panic sets --
// CXX: ::{{.*}}::A = 0x[[A:[0-9a-f]+]]
// The preamble, once: the incomplete id trait, the void unit, the alignment.
// CXX: template<class E> struct __kairo_tid;
// CXX: template<class E> inline constexpr unsigned int __kairo_type_id = __kairo_tid<E>::value;
// CXX: template<> struct __kairo_nv_s<void> {
// The record: a u32 tag, the site beside it, the aligned union; no niche.
// CXX: template<class T, class ... E> struct Panic {
// CXX-NEXT: enum class __kairo_Tag: unsigned int {
// CXX: ::__kairo_nv<T> value;
// CXX: __kairo_Tag __kairo_tag;
// CXX-NEXT: unsigned int __kairo_site;
// CXX-NEXT: static constexpr unsigned int __kairo_payload_offset = ::__kairo_max_align<__kairo_Ok_t, __kairo_Err_t<E> ...>(8);
// CXX-NEXT: union alignas(__kairo_payload_offset) {
// An element's tag is its id, and destroy / copy find the element by it.
// CXX: __kairo_tag(static_cast<__kairo_Tag>( ::__kairo_type_id<__type_pack_element<K, E ...>>)), __kairo_site()
// CXX: (( ::__kairo_type_id<E> == static_cast<unsigned int>(__kairo_tag) ?(void)(i = k):(void) 0,++ k), ...);
// CXX: static constexpr unsigned long __kairo_niche_count = 0;
// The user's TU: each element's id from Sema, before anything uses it.
// CXX: template<> struct __kairo_tid< ::{{.*}}::A> {
// CXX-NEXT: static constexpr unsigned int value = 0x[[A]]u;
// CXX: {{\[\[}}gnu::used, gnu::section("__kairo_panic_sites")]] static const::__kairo_panic_site __kairo_ps_{{[0-9a-f]+}} = {
// CXX-NEXT: {{[0-9]+}}u, 55u, 14u, "{{.*}}lang_item.k"
// CXX: {{\[\[}}gnu::used, gnu::section("__kairo_panic_sites")]] static const::__kairo_panic_site __kairo_ps_{{[0-9a-f]+}} = {
// CXX-NEXT: {{[0-9]+}}u, 56u, 14u, "{{.*}}lang_item.k"

// RUN: rm -rf %t.d
// RUN: %kairo %s --test-panic-type -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
