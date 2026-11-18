// RUN: %kfmt --stdout %s | diff -u %S/expected/imports_module.k -
// RUN: %kfmt --check %S/expected/imports_module.k
//
// Rule 5.1's exception: `inputs/kmod.k` exists beside this file, so
// `import inputs::kmod` would name that module, not the declaration
// `kmod` in `inputs`. The braces stay. The sibling with no such file
// loses them.

import inputs::{kmod};
import inputs::{other};
