// A library's name is read from its module.k's FIRST declaration only, by
// the resolver, before any parse (SearchRoot.k read_module_pin); the parser
// accepts a bare `module foo` anywhere at top level. A pin anywhere else in
// a module.k used to be accepted with no word and ignored: late/module.k
// below kept its folder name, and the only symptom was the importer's
// R011E. Now ModulePinCheck asks the resolver's own scanner whether the pin
// counts. A second pin, which the parser dropped, is an error as well.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/module_pins_late && { %kairo late/module.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=LATE
// RUN: cd %S/Inputs/module_pins_late && not %kairo late/module.k --type-check-only > /dev/null 2>&1
// LATE: module.k:2:1: error [R001E]: `module geo` is not the first declaration of this module.k, so it does not name the directory
//
// RUN: cd %S/Inputs/module_pins_late && { %kairo twice/module.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TWICE
// TWICE: module.k:2:1: error [R001E]: a second bare `module` declaration; a file names at most one library
// TWICE: module.k:1:1: note {{.*}}: the first pin is here
// TWICE-NOT: error
