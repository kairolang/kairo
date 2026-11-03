// What keys a `{K: V}` / `{T}`: everything conforming to builtin's Hash
// (Lib/builtin/base/hash.k). The primitives conform there (`extend i32 impl
// Hash`), their `op ==` the native one (ConformanceChecking::
// _native_implementation); a pointer hashes its address with no Kairo code;
// a Kairo struct conforms by declaring both requirements. usize and u64 are
// one C++ type on this target and both key a map in one program (one
// witness specialization, EmitPlan::_witness_row).

struct Pt {
    pub var x: i32
    pub var y: i32
}
extend Pt impl Hash {
    pub fn hash(const self) -> usize = to_usize(mix64(((self.x as u64) << 32) | (self.y as u32 as u64)))
    pub fn op ==(const self, const other: Pt) -> bool = (self.x == other.x) && (self.y == other.y)
}

fn main() -> i32 {
    var pts: {Pt: string}
    pts[Pt{x: 1, y: 2}] = "a"
    pts[Pt{x: 2, y: 1}] = "b"
    if (pts.size() != 2) || !pts.contains(Pt{x: 1, y: 2}) || pts.contains(Pt{x: 1, y: 1}) { return 1 }

    var u: {usize: i32}
    u[3usize] = 1
    var w: {u64: i32}
    w[3u64] = 2
    if (u[3usize] != 1) || (w[3u64] != 2) { return 2 }
    var z: {isize: i32}
    z[-1isize] = 5
    var l: {i64: i32}
    l[-1i64] = 6
    if (z[-1isize] != 5) || (l[-1i64] != 6) { return 3 }

    var b: {bool}
    b.insert(true)
    if !b.contains(true) || b.contains(false) { return 4 }
    var c: {char}
    c.insert('x')
    if !c.contains('x') { return 5 }
    var small: {u8: i32} = {1u8: 1, 2u8: 2}
    var tiny: {i8: i32} = {-1i8: 1}
    var mid: {u16: i32} = {300u16: 3}
    var mid2: {i16: i32} = {-300i16: 3}
    if (small[2u8] != 2) || (tiny[-1i8] != 1) || (mid[300u16] != 3) || (mid2[-300i16] != 3) { return 6 }
    var wide: {u128: i32}
    wide[(1u128 << 100) + 7u128] = 9
    if !wide.contains((1u128 << 100) + 7u128) || wide.contains(7u128) { return 7 }

    // -0.0 == +0.0: one key
    var f: {f64: i32}
    f[0.0] = 1
    f[-0.0] = 2
    if (f.size() != 1) || (f[0.0] != 2) { return 8 }
    var g: {f32}
    g.insert(1.5f32)
    if !g.contains(1.5f32) { return 9 }

    // pointers: the address
    var xs: [i32; 3] = [1, 2, 3]
    var ptrs: {unsafe *i32: i32}
    unsafe {
        ptrs[&xs[0] as unsafe *i32] = 10
        ptrs[&xs[2] as unsafe *i32] = 30
        if (ptrs[&xs[2] as unsafe *i32] != 30) || ptrs.contains(&xs[1] as unsafe *i32) { return 10 }
    }
    var nil: unsafe *i32 = &null
    ptrs[nil] = 0
    if ptrs.size() != 3 { return 11 }

    // string hashing is a function of the bytes, at every length class of
    // the byte hash (0, 1-3, 4-16, 17-48, past 48)
    var strs: {string}
    strs.insert("")
    strs.insert("ab")
    strs.insert("abcdefgh")
    strs.insert("abcdefghijklmnopqrstuvwxyz")
    strs.insert("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz0123456789")
    if !strs.contains("") || !strs.contains("ab") || !strs.contains("abcdefgh") { return 12 }
    if !strs.contains("abcdefghijklmnopqrstuvwxyz") { return 13 }
    if !strs.contains("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz0123456789") { return 14 }
    if strs.contains("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz012345678X") || strs.contains("ac") { return 15 }
    if ("abc".hash() != "abc".hash()) || ("abc".hash() == "abd".hash()) { return 16 }
    return 100
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// A builtin's `==` and a pointer's hash are the native operations.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<> struct Hash_witness<signed int> {
// CXX-NEXT: static decltype(sizeof(0)) hash(const signed int * self) noexcept {
// CXX-NEXT: return{{ ?}}::builtin::base::hash::__kairo_ext_i32::hash(self);
// CXX: static bool __kairo_op_eq(const signed int & self, const signed int & other) noexcept {
// CXX-NEXT: return(self == static_cast<decltype(other) &&>(other));
// CXX: template<> struct Hash_witness<signed int *> {
// CXX-NEXT: using __kairo_Self = signed int *;
// CXX-NEXT: static decltype(sizeof(0)) hash(const __kairo_Self * self) noexcept {
// CXX-NEXT: return reinterpret_cast<decltype(sizeof(0))>(* self);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 100
