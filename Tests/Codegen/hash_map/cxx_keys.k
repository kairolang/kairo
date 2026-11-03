// A C++ type keys a `{K: V}` with no Kairo code (Lib/builtin/base/hash.k):
// Hash's `hash` is `std::hash<X>` and its `op ==` is C++'s own `==`, member
// (CxxKey's defaulted one) or free (std::string's), so anything that keys a
// std::unordered_map keys a Kairo map. ConformanceChecking accepts the row
// (_native_implementation / _is_std_hash_slot); C++ checks the operations
// where the witness specialization is instantiated.
ffi "c++" import "cxx_key.h"

fn main() -> i32 {
    var m: {cxx::std::string: i32}
    m[make_str(3)] = 3
    m[make_str(5)] = 5
    if (m[make_str(3)] != 3) || !m.contains(make_str(5)) || m.contains(make_str(4)) { return 1 }
    if !m.erase(make_str(3)) || (m.size() != 1) { return 2 }

    var k: {CxxKey: i32}
    k[make_key(1, 2)] = 12
    k[make_key(2, 1)] = 21
    if (k[make_key(1, 2)] != 12) || (k.size() != 2) || k.contains(make_key(3, 3)) { return 3 }
    var s: {CxxKey}
    s.insert(make_key(4, 4))
    if s.insert(make_key(4, 4)) || !s.contains(make_key(4, 4)) { return 4 }
    return 100
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<> struct Hash_witness< ::CxxKey> {
// CXX-NEXT: static decltype(sizeof(0)) hash(const{{ ?}}::CxxKey * self) noexcept {
// CXX-NEXT: return static_cast<decltype(sizeof(0))>( ::std::hash< ::CxxKey> {
// CXX: static bool __kairo_op_eq(const{{ ?}}::CxxKey & self, const{{ ?}}::CxxKey & other) noexcept {
// CXX-NEXT: return(self == static_cast<decltype(other) &&>(other));

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 100
