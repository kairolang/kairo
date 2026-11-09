# Imports

The `import` statement brings names from other modules and external libraries into the current scope. Imports are how you access code defined in other files and C/C++ headers.

See [Modules](/docs/language/modules/) for how files organize into module namespaces and how the module system resolves import paths.

## Import Forms

```kairo
import math                              // import a module
import math::Vector3                     // import a specific symbol
import math::{Vector3, Matrix4}          // import multiple symbols
import math::*                           // wildcard import (discouraged)
import math as m                         // aliased import
import math::Vector3 as Vec3             // aliased symbol
import math::{Vector3 as Vec3}           // per-item alias
import self::util                        // the file beside this one
import module::config                    // from this module's root
```

The first word after `import` says where the path is looked for: nothing (a library or search directory), `self::` (the importing file's directory) or `module::` (the importing file's [module root](#module-imports)). Every other part of an import combines with either anchor: `import self::json::{parse, Value}`, `import module::util as u`, `import self::shapes::*`.

## Resolution Semantics

Each import form looks in **exactly one place**:

| Form | Looks in |
|------|----------|
| `import Foo` | the libraries and search directories: every [named library](/docs/language/modules/#naming-a-library), the working directory, every `-I` directory, `std` and `builtin` |
| `import self::Foo` | the importing file's own directory |
| `import module::Foo` | the importing file's [module root](#module-imports): the nearest directory, at or above it, that holds a `module.k` |

In that one place, `Foo` is the file `Foo.k` or the [library entry](/docs/language/modules/#library-entry-files) `Foo/module.k`. If both exist there, the import is an error (R005E) naming the two; rename or remove one.

A plain import never looks beside the importing file. Because the working directory is a search directory, a project compiled from its top directory (`kairo main.k`) reaches its top-level files with plain imports (`import router`), but a file in a subdirectory reaches the file next to it only as `import self::helpers`. A path that starts with a [library's name](/docs/language/modules/#naming-a-library) (`import geo::shapes`) resolves inside that library, and a file inside a library also reaches the library's files by their path in it (`import shapes`, from anywhere in the library).

Since an anchored import never consults the search directories, adding a file to a library or an `-I` directory can never change what `import self::x` or `import module::x` means, and a file beside the importer can never change what a plain `import x` means. Two different files answering one plain import from two search directories are an error at the import (R017E); the compiler never picks one.

### Resolution with `::`

`import Foo::bar` resolves the longest leading part of the path that names a module, then looks up the rest inside it:

1. Resolve `Foo::bar` as a module (`Foo/bar.k` or `Foo/bar/module.k`); if there is none,
2. resolve `Foo` (`Foo.k` or `Foo/module.k`) and look for the symbol `bar` inside it.

The anchor applies to the whole path: `import self::Foo::bar` looks for `Foo/bar.k` beside the importing file, then for the symbol `bar` in the `Foo.k` beside it.

```kairo
// Given, beside this file:
//   math.k                 contains `fn add(...)`
//   vector/module.k        library entry

import self::math::add        // resolves math.k, finds symbol `add`
import self::vector           // resolves vector/module.k
```

### Sibling imports

```kairo
// app/main.k, with app/util.k and app/net/socket.k beside it
import self::util                 // app/util.k
import self::net::socket          // app/net/socket.k
import self::util::{trim, split}  // symbols from app/util.k
```

`self::` names the importing file's directory: the file `x.k` or the library `x/module.k` next to it, and anything below it. It is the form for files that belong together but are not a library of their own.

### Module imports

```kairo
// project/module.k is empty: project/ is a module
// project/net/http/client.k
import module::config             // project/config.k
import module::net::socket        // project/net/socket.k
```

`module::` starts at the importing file's **module root**: the nearest directory, at or above the file, that holds a `module.k`. It is the same directory that decides who shares `prot` declarations ([Visibility Scopes](/docs/language/modules/#visibility-scopes)), so a file reaches any file of its own module the same way from any depth. The `module.k` may be empty. A file with no `module.k` above it belongs to no module, and `import module::x` there is an error (R069E) that says so; add a `module.k`, or use `self::` for a file beside it.

### Migrating from sibling-first imports

Older compilers looked for a plain `import Foo` beside the importing file first. A plain import that no library or search directory answers, but that finds `Foo` beside the importing file, still resolves to that file, but reports an error (R068E) with a fix-it that inserts `self::`:

```
app/main.k:1:8: error [R068E]: 'util' is not in any library or search directory; it is the file beside this one, which a plain import no longer reaches: write 'self::util'
```

The fallback exists only so one stale line does not cascade into unresolved-name errors. When a library or search directory does hold `Foo`, the plain import resolves there and the file beside the importer is ignored.

### Removed: `import module Foo`

`import module Foo` (with a space) forced the library form, `Foo/module.k`. It is removed: now that `Foo.k` and `Foo/module.k` in one place are an error, nothing is left to force. Writing it is an error (S089E) with a fix-it that deletes `module`; then choose the form for where `Foo` is (`import Foo`, `import self::Foo` or `import module::Foo`). Do not confuse it with `import module::Foo`, written with `::`, which anchors at the module root.

## Visibility on Imports

Imports default to **`priv`** (private). A private import brings names into the current file but does not re-export them to consumers of this module:

```kairo
priv import std::collections    // default, only visible in this file
pub import std::collections     // re-exported to consumers
prot import std::platform       // visible to sibling files in same library
```

An import makes a name reachable, not visible: a name the imported file declares `priv` (or leaves unmarked outside a module), or `prot` in another [module](/docs/language/modules/#visibility-scopes), is an error where it is used (R047E for a bare name from `import m::*`, SC242E for `m::name`), with a fix-it that makes the declaration `pub`.

### Re-export Pattern

Use `pub import` explicitly in library entry files to curate the public API:

```kairo
// network/module.k
pub import self::tcp       // consumers of "network" can access tcp
pub import self::udp       // consumers of "network" can access udp
priv import self::dns      // implementation detail, not re-exported
```

Consumers see only the public surface:

```kairo
import network

network::tcp::connect("example.com", 80)   // ok
network::udp::send_packet(data)            // ok
// network::dns::lookup(...)               // compile error: not exported
```

### Why Private by Default

Default-private prevents transitive dependency leakage. If `network.k` imports an internal utility module, consumers of `network` don't accidentally see that utility in their namespace. Public re-export is an explicit, intentional choice by the module author.

## Selective Imports

Selective imports bring specific items from a module:

```kairo
import math::{Vector3, Matrix4, cross_product}
```

Each item can have its own alias:

```kairo
import math::{Vector3 as Vec3, Matrix4 as Mat4}
```

Items can reference nested paths relative to the base:

```kairo
import std::collections::{HashMap, list::LinkedList}
```

Here `HashMap` resolves as `std::collections::HashMap` and `LinkedList` resolves as `std::collections::list::LinkedList`.

A wildcard inside a selective list is valid but unusual:

```kairo
import math::{*, Vector3 as Vec3}  // bring everything, but alias Vector3
```

## Wildcard Imports

```kairo
import math::*
```

Brings all public symbols from `math` into the current scope. Use sparingly, it obscures where names come from and can cause collisions. **Prefer selective imports.**

## Aliased Imports

```kairo
import math as m

m::Vector3(1.0, 2.0, 3.0)
```

The alias replaces the module name in the current scope. The original name (`math`) is **not** available, only `m`.

## FFI Header Imports

C and C++ headers are imported via the [`ffi` keyword](/docs/language/c-cpp-calling/#the-ffi-keyword):

```kairo
ffi "c++" import "graphics.hh"
ffi "c" import "legacy_api.h"
```

All declarations from the header are imported into the current namespace. Use `as` to namespace the import:

```kairo
ffi "c++" import "graphics.hh" as gfx

gfx::create_window(800, 600)
gfx::RenderContext()
```

### C++ `std` Namespace

If a C++ header defines names in the `std` namespace, those collide with Kairo's `std` module. The C++ standard library is accessible through `cxx::std`:

```kairo
import std                         // Kairo standard library
import cxx::std::vector            // C++ std::vector
import cxx::std::{cout, endl}      // C++ std output stream

std::io::println("Kairo")
cout << "C++" << endl
```

FFI imports of headers that define names in `std` are automatically redirected to `cxx::std`:

```kairo
ffi "c++" import "iostream"  // imported into cxx::std, not std
```

A name a header brings into a namespace with a using-declaration is a member of that namespace, as in C++. `<cmath>` puts the C library's `sqrt` in `std` with `using ::sqrt;`, so `cxx::std::sqrt(x)` finds it.

See [C/C++ Interop](/docs/language/c-cpp/) for the full FFI model.

## FFI Linkage Declarations

The `ffi` keyword also applies foreign linkage to individual declarations or blocks:

```kairo
// Single declaration
ffi "c++" fn create_window(i32, i32) -> *Window

// Block of declarations
ffi "c++" {
    fn gl_init()
    fn gl_clear(u32)
    class Renderer {
        fn draw(self, *Mesh)
    }
}
```

Declarations inside an `ffi` block are parsed normally but stamped with C/C++ linkage. See [C/C++ Interop](/docs/language/c-cpp-calling/#constraints-and-safety) for details on FFI constraints and capabilities.

## Import Cycles

Imports may form a cycle: `a` imports `b` while `b` imports `a`, a longer chain, or a file that imports itself. An import never needs to come "first", so the order of `import` lines and of files does not matter. Every module on a cycle sees the others' public declarations, so functions can call each other across it, a type can name a type from the other side, and a `pub import` re-exports through it:

```kairo
// node.k
import tree::*
pub struct Node { pub var owner: unsafe *Tree; pub var v: i32 }

// tree.k
pub import node::*
pub struct Tree { pub var root: unsafe *Node; pub var n: i32 }

// main.k
import tree::*          // Node arrives too, through tree's pub import
```

A cycle compiles with a warning, [R001W](/docs/language/diagnostics/#r001w-import-cycle), on the import that closes it. The warning names the cycle and suggests moving the shared declarations into a third module. A file that imports itself gets the same warning, with a fix-it removing the import, since a file always sees its own declarations. `-fno-import-cycles` turns every cycle into the error R001E. See [Circular Dependencies](/docs/language/modules/#circular-dependencies).

## Import Reference

| Form | Resolves to | Notes |
|------|-------------|-------|
| `import Foo` | `Foo.k` or `Foo/module.k` in a library or search directory | Never beside the importer (R068E) |
| `import self::Foo` | `Foo.k` or `Foo/module.k` beside the importing file | |
| `import module::Foo` | `Foo.k` or `Foo/module.k` at the module root | R069E outside any module |
| `import Foo::bar` | Symbol `bar` in `Foo` | Same place as `import Foo` |
| `import Foo::{a, b}` | Symbols `a`, `b` in `Foo` | Per-item aliases supported |
| `import Foo::*` | All public symbols from `Foo` | Avoid; prefer selective imports |
| `import Foo as m` | `Foo`, aliased to `m` | Original name unavailable |
| `import module Foo` | removed | S089E; fix-it deletes `module` |
| `ffi "c++" import "h.hh"` | C++ header | Optional `as` namespace |
| `ffi "c++" fn foo(...)` | Single decl with C++ linkage | |
| `ffi "c++" { ... }` | Block of decls with C++ linkage | |

Imports may form cycles; see [Import Cycles](#import-cycles).

## See also

- [Modules](/docs/language/modules/)
- [Circular Dependencies](/docs/language/modules/#circular-dependencies)
- [Library Entry Files](/docs/language/modules/#library-entry-files)
- [Module Visibility](/docs/language/modules/#module-visibility)
- [C & C++ Interoperability](/docs/language/c-cpp/)
- [The `ffi` keyword](/docs/language/c-cpp-calling/#the-ffi-keyword)
- [Namespace mapping](/docs/language/c-cpp-calling/#namespace-mapping)
