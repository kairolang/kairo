// Every builtin type an `extend` can target, each with one method,
// called and run: every integer and float,
// bool, void, char, string, [T], [T;], [T; N], {T}, {K: V}, and the generic
// forms, including `extend <T> [*T]` (a vector OF pointers is an ordinary
// target; a bare pointer is not, Tests/Sema/Check/extend_pointer_target.k).
// f80 and f128 exist only on some targets: extend_builtin_matrix_x86.k.
//
// An `extend [i32; 2]` compiles (CXXSpell::ext_scope_name spells its scope),
// and a static an extension gives a primitive
// (`i32::seven()`, `void::seven()`) is callable.

extend i8 { pub fn probe(self) -> i32 { return 1 } }
extend i16 { pub fn probe(self) -> i32 { return 1 } }
extend i32 { pub fn probe(self) -> i32 { return 1 } }
extend i64 { pub fn probe(self) -> i32 { return 1 } }
extend i128 { pub fn probe(self) -> i32 { return 1 } }
extend i256 { pub fn probe(self) -> i32 { return 1 } }
extend i512 { pub fn probe(self) -> i32 { return 1 } }
extend isize { pub fn probe(self) -> i32 { return 1 } }
extend u8 { pub fn probe(self) -> i32 { return 1 } }
extend u16 { pub fn probe(self) -> i32 { return 1 } }
extend u32 { pub fn probe(self) -> i32 { return 1 } }
extend u64 { pub fn probe(self) -> i32 { return 1 } }
extend u128 { pub fn probe(self) -> i32 { return 1 } }
extend u256 { pub fn probe(self) -> i32 { return 1 } }
extend u512 { pub fn probe(self) -> i32 { return 1 } }
extend usize { pub fn probe(self) -> i32 { return 1 } }
extend f16 { pub fn probe(self) -> i32 { return 1 } }
extend bf16 { pub fn probe(self) -> i32 { return 1 } }
extend f32 { pub fn probe(self) -> i32 { return 1 } }
extend f64 { pub fn probe(self) -> i32 { return 1 } }
extend f256 { pub fn probe(self) -> i32 { return 1 } }
extend f512 { pub fn probe(self) -> i32 { return 1 } }
extend bool { pub fn probe(self) -> i32 { return 1 } }
extend char { pub fn probe(self) -> i32 { return 1 } }
extend string { pub fn probe(self) -> i32 { return 1 } }
extend [i32] { pub fn probe(self) -> i32 { return 1 } }
extend [i32;] { pub fn probe(self) -> i32 { return 1 } }
extend [i32; 2] { pub fn probe(self) -> i32 { return 1 } }
extend {i32} { pub fn probe(self) -> i32 { return 1 } }
extend {i32: i32} { pub fn probe(self) -> i32 { return 1 } }
extend (i32, i32) { pub fn probe(self) -> i32 { return 1 } }
extend <T> [T] { pub fn gprobe(self) -> i32 { return 1 } }
extend <T> [*T] { pub fn pprobe(self) -> i32 { return 1 } }
extend <T> [T;] { pub fn gprobe(self) -> i32 { return 1 } }
extend <T> {T} { pub fn gprobe(self) -> i32 { return 1 } }
extend <K, V> {K: V} { pub fn gprobe(self) -> i32 { return 1 } }
extend i32 { pub fn seven() -> i32 { return 7 } }
extend void { pub fn seven() -> i32 { return 7 } }

fn view(s: [i32;]) -> i32 { return s.probe() + s.gprobe() }

fn main() -> i32 {
    var a: i8 = 1
    var b: i16 = 1
    var c: i32 = 1
    var d: i64 = 1
    var e: i128 = 1
    var f: i256 = 1
    var g: i512 = 1
    var h: isize = 1
    var n = a.probe() + b.probe() + c.probe() + d.probe() + e.probe() + f.probe() + g.probe() + h.probe()
    var ua: u8 = 1
    var ub: u16 = 1
    var uc: u32 = 1
    var ud: u64 = 1
    var ue: u128 = 1
    var uf: u256 = 1
    var ug: u512 = 1
    var uh: usize = 1
    n += ua.probe() + ub.probe() + uc.probe() + ud.probe() + ue.probe() + uf.probe() + ug.probe() + uh.probe()
    var fa: f16 = 1.0
    var fb: bf16 = 1.0
    var fc: f32 = 1.0
    var fd: f64 = 1.0
    var fe: f256 = 1.0
    var ff: f512 = 1.0
    n += fa.probe() + fb.probe() + fc.probe() + fd.probe() + fe.probe() + ff.probe()
    var t = true
    var ch = 'a'
    var s = "s"
    n += t.probe() + ch.probe() + s.probe()
    var x = 1
    var v: [i32] = [1, 2]
    var arr: [i32; 2] = [1, 2]
    var set: {i32} = {1}
    var map: {i32: i32} = {1: 2}
    var tup: (i32, i32) = (1, 2)
    var ptrs: [*i32] = [&x]
    n += v.probe() + v.gprobe() + view(v) + arr.probe() + set.probe() + set.gprobe()
    n += map.probe() + map.gprobe() + tup.probe() + ptrs.gprobe() + ptrs.pprobe()
    n += i32::seven() + void::seven()
    // 8 + 8 + 6 + 3 + 12 probes of 1, and two statics of 7.
    return n - 51
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t && %t
