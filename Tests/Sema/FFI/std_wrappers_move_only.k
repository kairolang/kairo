// std::optional, std::tuple, std::variant, std::expected
// and std::pair over a move-only Kairo class are MOVE. clang sees the
// Kairo class through a stand-in, which must not copy implicitly (else
// `optional<Mv>` reads trivially copyable, keeps COPY, and `var y = x`
// fails only in clang, CL001E, implicitly-deleted copy constructor). The
// stand-in declares the class's own transfers, so clang deletes each
// wrapper's defaulted copy itself. A move works, a second use is SC052E,
// copying a const one is SC182E naming the part that cannot be copied.
// `std::tuple<A, B>` could not be named at all (R032E "'tuple' is not
// generic"): libc++'s `template <> class tuple<>` has an empty PACK
// argument and was imported as a plain record named `tuple`.
// The other transfer shapes keep their category: a `= default` @copy and a
// @copy with a body are COPY inside a wrapper (no error), a deleted @copy
// makes the wrapper non-copyable, and a copy a header deletes itself
// (unique_ptr) keeps clang's own reason.

ffi "c++" import "expected"
ffi "c++" import "memory"
ffi "c++" import "optional"
ffi "c++" import "tuple"
ffi "c++" import "utility"
ffi "c++" import "variant"

class Mv {
    pub var id: i32 = 0
    fn Mv(self) { self.id = 3 }
    @move fn Mv(self, other: Self) { self.id = other.id; other.id = 0 }
}

fn copy_opt(const o: cxx::std::optional<Mv>) { var c = o }
fn copy_tup(const o: cxx::std::tuple<Mv, i32>) { var c = o }
fn copy_var(const o: cxx::std::variant<Mv, i32>) { var c = o }
fn copy_pair(const o: cxx::std::pair<Mv, i32>) { var c = o }
fn copy_exp(const o: cxx::std::expected<Mv, i32>) { var c = o }

class Dc {
    pub var id: i32 = 0
    fn Dc(self) { self.id = 1 }
    @copy fn Dc(self, const other: Self) = default
}

class Cb {
    pub var id: i32 = 0
    fn Cb(self) { self.id = 1 }
    @copy fn Cb(self, const other: Self) { self.id = other.id }
}

class Nt {
    pub var id: i32 = 0
    fn Nt(self) { self.id = 1 }
    @copy fn Nt(self, const other: Self) = delete
}

fn copy_uptr(const u: cxx::std::unique_ptr<Mv>) { var c = u }

fn shapes() {
    var a: cxx::std::optional<Dc>
    var a2 = a
    var a3 = a
    var b: cxx::std::pair<Cb, i32>
    var b2 = b
    var b3 = b
    var n: cxx::std::optional<Nt>
    var n2 = n
}

fn main() -> i32 {
    var o: cxx::std::optional<Mv>
    var o2 = o
    var o3 = o
    var t: cxx::std::tuple<Mv, i32>
    var t2 = t
    var t3 = t
    var plain: cxx::std::tuple<i32, f64, bool>
    var plain2 = plain
    var plain3 = plain
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: std_wrappers_move_only.k:30:56: error [SC182E]: cannot copy a value of type 'optional<Mv>': its type argument 'Mv' is not copyable
// CHECK: std_wrappers_move_only.k:31:58: error [SC182E]: cannot copy a value of type 'tuple<Mv, i32>': its type argument 'Mv' is not copyable
// CHECK: std_wrappers_move_only.k:32:60: error [SC182E]: cannot copy a value of type 'variant<Mv, i32>': its type argument 'Mv' is not copyable
// CHECK: std_wrappers_move_only.k:33:58: error [SC182E]: cannot copy a value of type 'pair<Mv, i32>': its field 'first' is not copyable
// CHECK: std_wrappers_move_only.k:34:61: error [SC182E]: cannot copy a value of type 'expected<Mv, i32>': its element type 'Mv' is not copyable
// CHECK: std_wrappers_move_only.k:54:59: error [SC182E]: cannot copy a value of type 'unique_ptr<Mv, default_delete<Mv>>': it declares a move constructor and no copy constructor
// CHECK: std_wrappers_move_only.k:64:14: error [SC182E]: cannot copy a value of type 'optional<Nt>': its type argument 'Nt' is not copyable
// CHECK: std_wrappers_move_only.k:70:14: error [SC052E]: 'o' is used after being moved
// CHECK: std_wrappers_move_only.k:73:14: error [SC052E]: 't' is used after being moved
