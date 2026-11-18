// f256 / f512 in f-strings: FmtBuf::put_f256 / put_f512 (fmt_buf.k) over
// num/softfloat_text.k's digits, laid out as rt/fmt_layout.c lays out every
// other float. `{}` is the shortest text that reads back to the same value
// (at most 73 / 149 digits); a precision is C's (`e`: digits after the point,
// `g`: significant digits), every digit exact and the last rounded to even.
// The expected text comes from an exact oracle (Scripts/softfloat_oracle/
// textor.py); width, fill, alignment, sign and `{x=}` go through the same
// number_ path as f64.

import std::io

fn main() -> i32 {
    var x1     = 0.1f256
    var nx     = -0.25f256
    var third  = 1.0f256 / 3.0
    var mx     = 1.61132571748576047361957211845200501064402387454966951747637125049607183e78913f256
    var tiny   = 0x1p-262378f256
    var big    = 123456789012345678901234567890.25f256
    var pz     = 0.0f256
    var nz     = -0.0f256
    var inf    = 1.0f256 / 0.0
    var ninf   = -1.0f256 / 0.0
    var nan    = 0.0f256 / 0.0
    var y1     = 0.1f512
    var third5 = 1.0f512 / 3.0
    var y2     = 1e1262611f512
    io::println(f"s1 [{x1}]")
    io::println(f"s2 [{third}]")
    io::println(f"s3 [{mx}]")
    io::println(f"s4 [{tiny}]")
    io::println(f"s5 [{big}]")
    io::println(f"e1 [{third:.30e}]")
    io::println(f"e2 [{third:E}]")
    io::println(f"e3 [{x1:.0e}]")
    io::println(f"g1 [{third:.5}]")
    io::println(f"g2 [{big:.40}]")
    io::println(f"w1 [{x1:>8}]")
    io::println(f"w2 [{x1:*<8}]")
    io::println(f"w3 [{x1:^9}]")
    io::println(f"w4 [{x1:+}]")
    io::println(f"w5 [{nx:08.3}]")
    io::println(f"z1 [{pz}]")
    io::println(f"z2 [{nz}]")
    io::println(f"z3 [{pz:.3e}]")
    io::println(f"i1 [{inf}]")
    io::println(f"i2 [{ninf}]")
    io::println(f"i3 [{nan}]")
    io::println(f"i4 [{inf:E}]")
    io::println(f"t1 [{y1}]")
    io::println(f"t2 [{third5}]")
    io::println(f"t3 [{third5:.60e}]")
    io::println(f"t4 [{y2}]")
    io::println(f"d1 {x1=}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: s1 [0.1]
// CHECK: s2 [0.333333333333333333333333333333333333333333333333333333333333333333333333]
// CHECK: s3 [1.61132571748576047361957211845200501064402387454966951747637125049607183e+78913]
// CHECK: s4 [2e-78984]
// CHECK: s5 [123456789012345678901234567890.25]
// CHECK: e1 [3.333333333333333333333333333333e-01]
// CHECK: e2 [3.33333333333333333333333333333333333333333333333333333333333333333333333E-01]
// CHECK: e3 [1e-01]
// CHECK: g1 [0.33333]
// CHECK: g2 [123456789012345678901234567890.25]
// CHECK: w1 [     0.1]
// CHECK: w2 [0.1*****]
// CHECK: w3 [   0.1   ]
// CHECK: w4 [+0.1]
// CHECK: w5 [-0000.25]
// CHECK: z1 [0]
// CHECK: z2 [-0]
// CHECK: z3 [0.000e+00]
// CHECK: i1 [inf]
// CHECK: i2 [-inf]
// CHECK: i3 [nan]
// CHECK: i4 [INF]
// CHECK: t1 [0.1]
// CHECK: t2 [0.3333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333332]
// CHECK: t3 [3.333333333333333333333333333333333333333333333333333333333333e-01]
// CHECK: t4 [1e+1262611]
// CHECK: d1 x1=0.1{{$}}
