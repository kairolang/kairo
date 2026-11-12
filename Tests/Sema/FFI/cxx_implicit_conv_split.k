// -fimplicit-conv and -fcxx-implicit-conv are two flags. -fimplicit-conv is
// the Kairo-side rules (the primitive lattice, ABI widening; on by default).
// -fcxx-implicit-conv lets C++'s own implicit conversions apply at a call
// that crosses into C++ (one user-defined conversion; a literal crossing as
// `const char[N]`); off by default, and -fimplicit-conv, even written out,
// does not turn it on. Each quadrant, on a crossing call (lines 19-20), a
// crossing initialisation (line 21) and a Kairo-side widening (line 23).
// The widening into a C++ constructor's parameter (line 22) is the Kairo
// argument's own conversion, so it follows -fimplicit-conv: under
// -fno-implicit-conv no C++ route is found even with -fcxx-implicit-conv.
ffi "c++" import "cxx_user_conversion.h"
ffi "c++" import "cxx_implicit_conv_split.h"

fn wide(x: i64) -> i64 { return x }

fn main() -> i32 {
    var a = A(7)
    var k: i32 = 3
    var n = len("hello")
    n += take(a)
    var v: View = "hi"
    n += takew(k)
    return n + len(v) + (wide(k) as i32)
}

// --- lit wiring -----------------------------------------------------------
// Neither flag (the default) and -fimplicit-conv written out: no crossing
// conversion; the note names -fcxx-implicit-conv and the fix-it the cast.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefixes=OFF,WON,KOK
// RUN: { %kairo %s --type-check-only -fimplicit-conv 2>&1 || true; } | %FileCheck %s --check-prefixes=OFF,WON,KOK
// RUN: { %kairo %s --type-check-only -fcxx-implicit-conv -fno-cxx-implicit-conv 2>&1 || true; } | %FileCheck %s --check-prefixes=OFF,WON,KOK
// OFF: cxx_implicit_conv_split.k:19:13: error [SC063E]: no matching overload for call to 'len'
// OFF: fix-it:{{.*}}:{19:24-19:24}:" as View"
// OFF: note [{{[A-Z0-9]+}}]: C++ would convert the argument to 'View' implicitly through 'View({{.*}})'; Kairo applies no C++ implicit conversion unless -fcxx-implicit-conv is given: write 'as View', or pass -fcxx-implicit-conv
// OFF: cxx_implicit_conv_split.k:20:10: error [SC063E]: no matching overload for call to 'take'
// OFF: fix-it:{{.*}}:{20:16-20:16}:" as B"
// OFF: implicitly through 'B(const A&)'; Kairo applies no C++ implicit conversion unless -fcxx-implicit-conv is given
// OFF: cxx_implicit_conv_split.k:21:19: error [SC028E]: cannot convert 'string' to 'View'
// OFF: fix-it:{{.*}}:{21:23-21:23}:" as View"
// OFF: note [{{[A-Z0-9]+}}]: C++ would convert the value to 'View' implicitly through 'View({{.*}})'; Kairo applies no C++ implicit conversion unless -fcxx-implicit-conv is given: write 'as View', or pass -fcxx-implicit-conv
// WON: cxx_implicit_conv_split.k:22:10: error [SC063E]: no matching overload for call to 'takew'
// WON: fix-it:{{.*}}:{22:17-22:17}:" as Wide"
// WON: implicitly through 'Wide(i64)'; Kairo applies no C++ implicit conversion unless -fcxx-implicit-conv is given
// KOK-NOT: cxx_implicit_conv_split.k:23:{{[0-9]+}}: error
//
// -fcxx-implicit-conv alone, and with -fimplicit-conv: everything converts.
// RUN: rm -rf %t.d
// RUN: %kairo %s -fcxx-implicit-conv -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 20
// RUN: %kairo %s --type-check-only -fimplicit-conv -fcxx-implicit-conv
//
// -fno-implicit-conv: the crossing stays an error and the widening is one;
// the widening ahead of Wide(long) is too, so no C++ route is named there.
// RUN: { %kairo %s --type-check-only -fno-implicit-conv 2>&1 || true; } | %FileCheck %s --check-prefixes=OFF,KNO
// KNO: cxx_implicit_conv_split.k:22:10: error [SC063E]: no matching overload for call to 'takew'
// KNO-NOT: C++ would convert
// KNO: cxx_implicit_conv_split.k:23:{{[0-9]+}}: error [SC063E]: no matching overload for call to 'wide'
//
// -fno-implicit-conv -fcxx-implicit-conv: the C++ conversions apply (a
// literal crosses as its bytes; no Kairo-side conversion is involved), the
// Kairo widening is still an error, and so is the widening ahead of Wide(long).
// RUN: { %kairo %s --type-check-only -fno-implicit-conv -fcxx-implicit-conv 2>&1 || true; } | %FileCheck %s --check-prefix=MIX
// MIX-NOT: cxx_implicit_conv_split.k:{{(19|20|21)}}:{{[0-9]+}}: error
// MIX: cxx_implicit_conv_split.k:22:10: error [SC063E]: no matching overload for call to 'takew'
// MIX-NOT: C++ would convert
// MIX: cxx_implicit_conv_split.k:23:{{[0-9]+}}: error [SC063E]: no matching overload for call to 'wide'
