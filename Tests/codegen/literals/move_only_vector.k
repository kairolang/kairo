// A vector literal whose elements cannot be copied moves each element into
// the vector (collections.mdx, Vectors): a temporary is built in `push`'s
// parameter and moved into its slot, a named value is moved into the
// parameter first. `M` declares a move constructor and no copy constructor,
// so a copy anywhere would not compile; the counters pin the moves.

static made: i32 = 0
static moved: i32 = 0
static dropped: i32 = 0

class M {
    pub var n: i32
    pub fn M(self, n: i32) { self.n = n; made += 1 }
    @move pub fn M(self, other: Self) { self.n = other.n; other.n = -1; moved += 1 }
    pub fn op finally(self) { if self.n != -1 { dropped += 1 } }
}

fn run() -> i32 {
    // Three temporaries: three objects made, one move each.
    var v: [M] = [M(1), M(2), M(3)]
    if v.size() != 3 || v[0].n != 1 || v[1].n != 2 || v[2].n != 3 { return 1 }
    if made != 3 || moved != 3 { return 2 }

    // A named value among temporaries, in written order: `a` costs the
    // move into the parameter as well.
    var a = M(10)
    var w: [M] = [a, M(11), (M(12))]
    if w.size() != 3 || w[0].n != 10 || w[1].n != 11 || w[2].n != 12 { return 3 }
    if made != 6 || moved != 7 { return 4 }

    // One element, and the vector still grows afterwards.
    var one: [M] = [M(20)]
    one.push(M(21))
    if one.size() != 2 || one[0].n != 20 || one[1].n != 21 { return 5 }
    return 0
}

fn main() -> i32 {
    var r = run()
    if r != 0 { return r }
    // Every value constructed is destroyed once, wherever it was moved to.
    if dropped != made { return 9 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// The vector is filled where it is declared, through `reserve` and `push`:
// no backing array, and no container is transferred.
// RUN: %kairo %s --print-ir 2>/dev/null | %FileCheck %s --check-prefix=CXX
// CXX: Vector< ::move_only_vector::M> w = ::builtin::containers::vector::Vector< ::move_only_vector::M>();
// CXX-NEXT: __kairo_ext_Vector::reserve<{{.*}}move_only_vector::M>((& w), static_cast<decltype(sizeof(0))>(3));
// CXX-NEXT: __kairo_ext_Vector::push<{{.*}}move_only_vector::M>((& w), static_cast<{{.*}}move_only_vector::M{{ ?}}>(static_cast<{{.*}}move_only_vector::M &&>(a)));
// CXX-NEXT: __kairo_ext_Vector::push<{{.*}}move_only_vector::M>((& w), {{.*}}move_only_vector::M(11));
// CXX-NEXT: __kairo_ext_Vector::push<{{.*}}move_only_vector::M>((& w), {{.*}}move_only_vector::M(12));

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
