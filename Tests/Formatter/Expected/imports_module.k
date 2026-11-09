// RUN: %kfmt --stdout %s | diff -u %S/Expected/imports_module.k -
// RUN: %kfmt --check %S/Expected/imports_module.k
//
// Rule 5.1's exception: `Inputs/kmod.k` exists beside this file, so
// `import Inputs::kmod` would name that module, not the declaration
// `kmod` in `Inputs`. The braces stay. The sibling with no such file
// loses them.

import Inputs::{kmod}
import Inputs::other
