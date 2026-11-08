// A panic type id hashes the type's C++ spelling. `usize` is spelled
// `decltype(sizeof(0))`, which on this target IS `u64`'s `unsigned long`:
// one C++ type, so one id, or the TU holding both sets would define
// `__kairo_tid<unsigned long>` twice. Two sets with one each get one
// specialization; one set with both is the type id collision error, which
// says why. `Panic<i32, usize>` and `Panic<i32, u64>` are then one C++
// type too, explicitly instantiated once (P256, as `Box<usize>` beside a
// `Box<u64>` is: Codegen/generics/size_type_one_instance.k).
fn fu(n: i32) panic(usize) -> i32 { if n == 1 { panic 7 as usize }  return n }
fn fw(n: i32) panic(u64) -> i32 { if n == 2 { panic 9 as u64 }  return n }
fn main() -> i32 {
    var a = try fu(1) catch e: usize => e as i32
    var b = try fw(2) catch e: u64 => 100 + (e as i32)
    var c = (try fu(3) catch => 0) + (try fw(4) catch => 0)
    return a + b + c   // 7 + 109 + 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}builtin_one_cxx_type.k
// IR-COUNT-1: template<> struct __kairo_tid<
// IR-NOT:     template<> struct __kairo_tid<

// RUN: { %kairo %S/Inputs/builtin_one_cxx_type_set.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=SET
// SET: builtin_one_cxx_type_set.k:{{[0-9]+}}:{{[0-9]+}}: error [SC223E]: 'u64' and 'usize' cannot be in one panic set: on this target both are the C++ type 'unsigned long', so their tags are one

// REQUIRES: host-linux, host-x86_64

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 123
