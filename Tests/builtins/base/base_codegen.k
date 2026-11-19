// Codegen properties of the base subsystem at -O2 on x86-64:
//   - `a < b` through a generic `T impl Ord` on two i32 is one `icmp slt`;
//   - hashing a u64 through `Hash` is two folds: no call, no branch;
//   - `move()` compiles to nothing: three moves of a move-only value are the
//     same loads and stores as returning the parameter, and of an i64 the
//     parameter itself;
//   - `Iterator::next` on a generator over a slice inlines into the loop
//     that drives it: no call and no frame allocation remain.

fn <T impl Ord> less(a: T, b: T) -> bool = a < b

@no_inline fn lt_i32(a: i32, b: i32) -> bool = less(a, b)

@no_inline fn hash_u64(v: u64, seed: u64) -> u64 {
    var h = Hasher(seed)
    v.hash(&h)
    return h.finish()
}

// Move-only, with an inline move: what `move()` costs is all that is left.
class Owned {
    var p: unsafe *u8
    var n: usize

    pub inline fn Owned(self, n: usize) {
        self.p = &null
        self.n = n
    }

    @move inline fn Owned(self, other: Self) {
        self.p  = other.p
        self.n  = other.n
        other.p = &null
    }

    inline fn op finally(self) {
        if self.p != &null {
            __builtin_trap()
        }
    }
}

@no_inline fn moved3(o: Owned) -> Owned = move(move(move(o)))
@no_inline fn plain(o: Owned) -> Owned = o
@no_inline fn moved3_int(x: i64) -> i64 = move(move(move(x)))

fn walk(const xs: [const i64;]) -> yield i64 {
    for x in xs {
        yield x
    }
}

@no_inline fn sum_yield(const xs: [const i64;]) -> i64 {
    var g          = walk(xs)
    var t: i64     = 0
    while true {
        var x = g.next()
        if !x? {
            break
        }

        t += x ?? 0
    }

    return t
}

fn main() -> i32 {
    var a: [i64; 4] = [1, 2, 3, 4]
    var s           = unsafe Slice<const i64>(&a[0] as unsafe *const i64, 4)
    var m           = moved3(Owned(1))
    var p           = plain(Owned(2))
    var bad         = 0
    if !lt_i32(1, 2) || lt_i32(2, 1) {
        bad += 1
    }

    if sum_yield(s) != 10 || moved3_int(7) != 7 || m.n + p.n != 3 {
        bad += 2
    }

    if hash_u64(1, 2) == hash_u64(2, 2) {
        bad += 4
    }

    return bad
}

// --- lit wiring ---
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -O2 --target=x86_64-linux-gnu -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 --target=x86_64-linux-gnu --emit=llvm-ir -o %t.ll --cache-dir %t.d
// RUN: %FileCheck %s --check-prefix=IR --input-file=%t.ll
// RUN: %kairo %s -O2 --target=x86_64-linux-gnu -S -o %t.s --cache-dir %t.d
// RUN: %FileCheck %s --check-prefix=ASM --input-file=%t.s
//
// IR-LABEL: define {{.*}}6lt_i32Eii(
// IR-NEXT:  entry:
// IR-NEXT:    icmp slt i32 %a, %b
// IR-NEXT:    ret i1
//
// IR-LABEL: define {{.*}}6moved3E{{.*}}(
// IR-NOT:     call
// IR:         store ptr null, ptr %o
// IR-NOT:     call
// IR:         ret void
// IR-LABEL: define {{.*}}5plainE{{.*}}(
// IR-NOT:     call
// IR:         store ptr null, ptr %o
// IR-NOT:     call
// IR:         ret void
//
// IR-LABEL: define {{.*}}10moved3_intEl(i64 noundef returned %x)
// IR-NEXT:  entry:
// IR-NEXT:    ret i64 %x
//
// IR-LABEL: define {{.*}}9sum_yieldE{{.*}}(
// IR-NOT:     _Znwm
// IR-NOT:     call {{.*}}@_ZN
// IR:         ret i64
// IR-NEXT:  }
//
// ASM-LABEL: {{^}}_ZN{{.*}}8hash_u64Emm:
// ASM-NOT:     call
// ASM-NOT:     j{{[a-z]+}} 
// ASM:         mulq
// ASM-NOT:     call
// ASM-NOT:     j{{[a-z]+}} 
// ASM:         mulq
// ASM-NOT:     call
// ASM-NOT:     j{{[a-z]+}} 
// ASM:         retq
