// The lattice does not change across a module boundary, a generic, or a
// nested call (conversion-lattice.mdx s2: one relation for every site).
// Inputs/module_generic/numlib.k declares the callees: plain functions, a
// generic `pass<T>`, and a generic class `Cell<T>`.
//
//   ok.k  -- every conversion W: numlib's results widened at a declared
//            type, an argument widened into numlib's parameter (also
//            nested, and through a deduced T), an instance's constructor
//            and method parameter. Built and run: exit 26.
//   bad.k -- the E twin of each: SC028E at a declared type, SC063E with the
//            candidate note (in numlib.k) at an argument, whatever the
//            value came through.
//
// An EXPLICIT generic argument (`pass<u32>(x)`) belongs here too, and is
// xfail_explicit_generic_arg.k: today it is overridden by deduction.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/module_generic && { %kairo bad.k --type-check-only 2>&1 || true; } \
// RUN:   | %FileCheck %s --check-prefix=BAD --implicit-check-not='error [' --implicit-check-not='warning ['
// BAD: bad.k:6:18: error [SC028E]: cannot convert 'i64' to 'i32'; the conversion may lose value and needs an explicit 'as'
// BAD: bad.k:7:13: error [SC063E]: no matching overload for call to 'take_i64'
// BAD-NEXT: numlib.k:3:5: note [I900N]: candidate not viable: cannot convert argument of type 'f64' to parameter 'x' of type 'i64'
// BAD: bad.k:8:18: error [SC028E]: cannot convert 'f64' to 'i64'; the conversion may lose value and needs an explicit 'as'
// BAD: bad.k:9:13: error [SC063E]: no matching overload for call to 'take_i64'
// BAD-NEXT: numlib.k:3:5: note [I900N]: candidate not viable: cannot convert argument of type 'u64' to parameter 'x' of type 'i64'
// BAD: bad.k:10:13: error [SC063E]: no matching overload for call to 'Cell'
// BAD-NEXT: numlib.k:14:5: note [I900N]: candidate not viable: cannot convert argument of type 'f64' to parameter 'v' of type 'i32'
// BAD-NOT: bad.k:11:
// BAD: bad.k:12:5: error [SC063E]: no matching overload for call to 'put'
// BAD-NEXT: numlib.k:16:5: note [I900N]: candidate not viable: cannot convert argument of type 'f64' to parameter 'v' of type 'i64'

// RUN: cd %S/Inputs/module_generic && { %kairo ok.k --type-check-only 2>&1 || true; } \
// RUN:   | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: cd %S/Inputs/module_generic && %kairo ok.k -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 26
