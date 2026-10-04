# Imports

The `import` statement brings names from other modules and external libraries into the current scope. Imports are how you access code defined in other files and C/C++ headers.

See [Modules](/docs/language/modules) for how files organize into module namespaces and how the module system resolves import paths.

## Import Forms

```kairo
import math                              // import a module
import math::Vector3                     // import a specific symbol
import math::{Vector3, Matrix4}          // import multiple symbols
import math::*                           // wildcard import (discouraged)
import math as m                         // aliased import
import math::{Vector3 as Vec3}           // per-item alias
import module math                       // library-only (skip file lookup)
```

## Resolution Semantics

When you write `import Foo`, the compiler resolves it in this order:

1. **File first:** look for `Foo.k` as a sibling file.
2. **Library fallback:** if no `Foo.k` exists, look for `Foo/module.k` (library entry).
3. **Ambiguity warning:** if both `Foo.k` and `Foo/module.k` exist, the import resolves to `Foo.k` and the compiler emits a warning:
   > ambiguous import 'Foo' resolves to Foo.k, but Foo/module.k also exists; rename the file or use `import module Foo` to import the library

The `module` modifier overrides this: `import module Foo` skips step 1 and resolves **only** against `Foo/module.k`. If no library entry exists, the compiler errors.

### Resolution with `::`

`import Foo::bar` applies the same file-first rule to `Foo`:

1. Resolve `Foo` -> `Foo.k` (or `Foo/module.k` if no `Foo.k`).
2. Look for symbol `bar` inside the resolved module.

The `::` does not change the resolution strategy. If you want `bar` to resolve as a **library submodule** (`Foo/bar/module.k`), use `import module Foo::bar`.

```kairo
// Given:
//   math.k                 contains `fn add(...)`
//   math/module.k          library entry
//   math/vector/module.k   submodule

import math::add              // resolves math.k, finds symbol `add`
import module math::vector    // resolves math/module.k, finds submodule vector
```

## Visibility on Imports

Imports default to **`priv`** (private). A private import brings names into the current file but does not re-export them to consumers of this module:

```kairo
priv import std::collections    // default, only visible in this file
pub import std::collections     // re-exported to consumers
prot import std::platform       // visible to sibling files in same library
```

### Re-export Pattern

Use `pub import` explicitly in library entry files to curate the public API:

```kairo
// network/module.k
pub import tcp       // consumers of "network" can access tcp
pub import udp       // consumers of "network" can access udp
priv import dns      // implementation detail, not re-exported
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

## Library-Only Imports

```kairo
import module math
```

Skips the file-first lookup and resolves **only** against the library entry (`math/module.k`). Use this when both `math.k` and `math/module.k` exist and you specifically want the library version.

If no `math/module.k` exists, this is a compile error, it does not fall back to `math.k`.

## FFI Header Imports

C and C++ headers are imported via the `ffi` keyword:

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

std::println("Kairo")
cout << "C++" << endl
```

FFI imports of headers that define names in `std` are automatically redirected to `cxx::std`:

```kairo
ffi "c++" import "iostream"  // imported into cxx::std, not std
```

See [C/C++ Interop](/docs/language/c-cpp) for the full FFI model.

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

Declarations inside an `ffi` block are parsed normally but stamped with C/C++ linkage. See [C/C++ Interop](/docs/language/c-cpp) for details on FFI constraints and capabilities.

## Import Reference

| Form | Resolves to | Notes |
|------|-------------|-------|
| `import Foo` | `Foo.k`, fallback `Foo/module.k` | File-first resolution |
| `import Foo::bar` | Symbol `bar` in `Foo` | `::` does not change resolution |
| `import Foo::{a, b}` | Symbols `a`, `b` in `Foo` | Per-item aliases supported |
| `import Foo::*` | All public symbols from `Foo` | Avoid; prefer selective imports |
| `import Foo as m` | `Foo.k` or `Foo/module.k`, aliased to `m` | Original name unavailable |
| `import module Foo` | `Foo/module.k` only | Explicit library import; errors if no entry |
| `ffi "c++" import "h.hh"` | C++ header | Optional `as` namespace |
| `ffi "c++" fn foo(...)` | Single decl with C++ linkage | |
| `ffi "c++" { ... }` | Block of decls with C++ linkage | |