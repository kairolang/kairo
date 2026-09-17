// rule: `std::cout << x` resolves `operator<<` on an imported stream type,
// through a system header: the member `basic_ostream::operator<<(int)` must
// win over every other arithmetic overload and over the free `std::operator<<`
// set ADL brings in. The operand is a TYPED i32 on purpose: an untyped `42`
// ranks Exact against every integer and float overload under Kairo's
// literal rule (Spec: the literal takes the type), which is a deliberate
// divergence from C++ and would make this case a test of that rule instead.

ffi "c++" import "iostream"

fn say() {
    var x: i32 = 42
    cxx::std::cout << x
    cxx::std::cout << 50 as i16
}

// --- lit wiring -----------------------------------------------------------
// PARITY CASE. The .cpp beside this file is the ORACLE: the assertion is that
// kairo and clang reach the same verdict. See Tests/parity_check.py.
//
// Header roots are hard-passed by lit (--sysroot / --resource-dir, see
// lit.cfg.py): kairo takes them only from flags.
//
// RUN: %parity %s
// REQUIRES: clang
