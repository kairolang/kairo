// CASE 6: transitivity wall. main imports foo; foo does `priv import bar::*`.
// A private import edge is NOT an export, so bar's names (id, Box, limit,
// secret) must be ABSENT from main's overlay. foo's OWN name `sub` must be
// present. Expect: overlay has `foo` (module handle); walking foo sees `sub`
// but NOT bar's names.

import foo

fn use_transitivity() -> i32 {
    return foo::sub(5, 2)
}
