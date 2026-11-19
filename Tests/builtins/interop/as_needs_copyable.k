// `as` to a C++ container copies each element, so it exists only for
// elements that are `Copyable`; a move-only element type has `into_cxx()`
// and no `as`. Sema does not check the bound of an extension member, so the
// error is clang's, reported at the conversion in the library, with the
// unmet `Copyable` in its note; it does not name `into_cxx`.

ffi "c++" import "vector"
ffi "c++" import "unordered_map"
ffi "c++" import "unordered_set"

class Tok impl Hash {
    pub var id: i64

    pub fn Tok(self, id: i64) {
        self.id = id
    }

    @move pub fn Tok(self, other: Self) {
        self.id  = other.id
        other.id = -1
    }

    pub fn op == (const self, const o: Tok) -> bool {
        return self.id == o.id
    }

    fn hash(const self, @inout h: Hasher) {
        h.write_usize(self.id as usize)
    }
}

fn main() -> i32 {
    var v = Vector<Tok>()
    var m = HashMap<Tok, i32>()
    var s = HashSet<Tok>()
    var a = v as cxx::std::vector<Tok>
    var b = m as cxx::std::unordered_map<Tok, i32>
    var c = s as cxx::std::unordered_set<Tok>
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// CHECK: cxx_containers.k:{{[0-9]+}}:{{[0-9]+}}: error [CL001E]: no matching function for call to '__kairo_op_as___std__vector_T_'
// CHECK: note [I900N]: because '::as_needs_copyable::Tok' does not satisfy 'Copyable_c'
// CHECK: cxx_containers.k:{{[0-9]+}}:{{[0-9]+}}: error [CL001E]: no matching function for call to '__kairo_op_as___std__unordered_map_K__V_'
// CHECK: note [I900N]: because '::as_needs_copyable::Tok' does not satisfy 'Copyable_c'
// CHECK: cxx_containers.k:{{[0-9]+}}:{{[0-9]+}}: error [CL001E]: no matching function for call to '__kairo_op_as___std__unordered_set_T_'
// CHECK: note [I900N]: because '::as_needs_copyable::Tok' does not satisfy 'Copyable_c'
