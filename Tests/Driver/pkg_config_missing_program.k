// --pkg-config with $PKG_CONFIG naming a program that does not exist is a
// user error, U019E naming the flag's package and the program, exit 1 --
// not an ICE. HostSystem::pkg_config reports it as a panic(PkgConfigError)
// that CompilerSetup catches (safe pointers pass 2, Batch D: the first
// recoverable error path in the compiler moved from a bool + error-string
// out-parameter to a declared panic set). No pkg-config is needed on the
// host. A second package is still tried after the first fails.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { env PKG_CONFIG=%t.no-such-dir/pkg-config %kairo %s --pkg-config alpha --pkg-config beta --type-check-only 2>&1; echo "exit $?"; } | %FileCheck %s
// CHECK: error [U019E]: --pkg-config alpha: {{.*}}pkg-config does not exist
// CHECK: error [U019E]: --pkg-config beta: {{.*}}pkg-config does not exist
// CHECK: exit 1
