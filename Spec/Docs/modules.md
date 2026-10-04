# Modules

Kairo's module system maps source files and directories to namespaces. Every `.k` file is a module. A directory containing a `module.k` entry file is a library. Use the `module` keyword to declare namespaces within a file, similar to C++ `namespace`.

See [Imports](/docs/language/imports) for how to bring names from modules into scope.

## File-to-Module Mapping

Each `.k` file is automatically a module named after the file (without the `.k` extension):

```
project/
  main.k         <- module "main"
  math.k         <- module "math"
  utils/
    module.k     <- library entry for "utils"
    strings.k    <- module "utils::strings"
    io.k         <- module "utils::io"
    internal/
      helpers.k  <- module "utils::internal::helpers"
```

Nested files create nested module names via `::`. A file at `utils/io.k` is accessible as the module `utils::io`.

### Module paths are C++ namespaces

A module's path is exactly its C++ namespace. `utils/strings.k` under a root named `utils` is `utils::strings` in Kairo and `namespace utils::strings` in the emitted C++; a `module codec { }` block inside it is `utils::strings::codec`. The mapping is fixed by the file's location in its root — not by how any importer spelled the import, not by an alias, and not by the directory the root happens to be checked out in — so the C++ name of a declaration is the same in every build of the same tree.

The entry file is the exception: it has no module path, so its declarations are emitted in a namespace named after the file's stem. `main.k` becomes `namespace main`; a stem that is not a valid C++ identifier is rewritten into one. Within it, `priv` and `internal` declarations sit in an unnamed namespace and cannot be reached from any other translation unit. `main` itself is at global scope. A file-scope declaration with no visibility written is `pub`.

Two files under one root that both open `module codec` reopen one namespace, as in C++. Reopening never crosses a root.

## Library Entry Files

A directory with a `module.k` file is a **library**. The entry file controls what the library exports publicly:

```kairo
// utils/module.k
pub import strings    // re-export utils/strings.k
pub import io         // re-export utils/io.k
priv import internal  // NOT re-exported (implementation detail)
```

Imports inside `module.k` are **relative to the directory**. `pub import strings` resolves to `utils/strings.k`.

Consumers of the library see only the public API:

```kairo
import utils

utils::strings::trim("  hello  ")    // from utils/strings.k
utils::io::read_file("data.txt")     // from utils/io.k
// utils::internal::...              // compile error: not exported
```

The library entry file is the public face of the library. Use it to re-export submodules, hide internal organization, and present a clean API boundary.

## Module Namespaces

The `module` keyword declares a namespace within a file. It is equivalent to C++ `namespace`:

```kairo
module serialization {
    pub fn to_json(data: Config) -> string { ... }
    pub fn from_json(input: string) panic -> Config { ... }

    priv fn escape_string(s: string) -> string { ... }
}

serialization::to_json(my_config)
```

### Anonymous Modules

A module without a name creates a scope for grouping declarations without introducing a named namespace:

```kairo
module {
    var internal_state: i32 = 0
    // not accessible from outside this block
}
```

### Nested Modules

Modules can be nested:

```kairo
module api {
    pub module v1 {
        pub fn handle_request(req: Request) -> Response { ... }
    }

    pub module v2 {
        pub fn handle_request(req: Request) -> Response { ... }
    }
}

api::v1::handle_request(req)
api::v2::handle_request(req)
```

## Module Visibility

Modules themselves have visibility. The default is `pub`:

```kairo
pub module api {
    // accessible to consumers
    fn handle_request(req: Request) -> Response { ... }
}

priv module cache {
    // only accessible within this file
    var store: {string: Data} = {}
}

prot module platform {
    // accessible within this file and sibling files in the library
    fn detect_os() -> string { ... }
}
```

### Visibility Scopes

| Modifier | Scope |
|---|---|
| `pub` (default) | Any module that imports this module |
| `priv` | Current file only |
| `prot` | Current file and sibling files in the same library subtree |

`prot` (protected) is scoped to the **library subtree**, not the immediate directory. Any file anywhere under a library's directory tree can access `prot` declarations from any other file in that same library. This is analogous to "package-private" in other languages.

## Module Reopening

A module can be reopened across multiple files to extend its contents:

```kairo
// encoding.k
pub module codec {
    pub fn encode_base64(data: [byte]) -> string { ... }
}
```

```kairo
// compression.k
import encoding::codec

pub module codec {
    pub fn compress(data: [byte]) -> [byte] { ... }
}
```

```kairo
// main.k
import encoding
import compression

encoding::codec::encode_base64(data)    // defined in encoding.k
compression::codec::compress(data)      // defined in compression.k
```

### Reopening Rules

- Reopening a module with different visibility than the original is a compile error.
- Reopening may only **add** new top-level declarations (functions, types, constants). It cannot modify existing declarations or add members to types defined in the original.
- Both declarations must be at file scope (not nested inside other modules).

## Scope Resolution (`::`

The `::` operator resolves names uniformly across all scoping contexts:

| Context | Example |
|---|---|
| Module access | `std::println(...)` |
| Library submodule | `math::vector::cross_product(...)` |
| Class static members | `Counter::count` |
| Enum variants | `Direction::North` |
| Nested types | `Packet::Header` |
| Base class methods | `Base::method(self)` |

There is no separate syntax for module access vs type member access, all use `::`.

## The Standard Library (`std`)

`std` is not automatically imported. It must be imported explicitly:

```kairo
import std

std::println("hello")
@create i32(42)
```

Individual items can be imported selectively:

```kairo
import std::{println, create}

println("hello")
```

**Core language primitives** (`i32`, `string`, `bool`, `[T]`, etc.) and **built-in syntax** (`if`, `for`, `match`, etc.) are always available without any import. Only **standard library functions and types** (`std::println`, `std::Error`, `std::Shared`, etc.) require an explicit import.

See [Imports](/docs/language/imports) for import syntax and the `pub import` pattern for re-exporting.

## Circular Dependencies

Circular imports are a compile error:

```kairo
// a.k
import b    // compile error if b.k imports a

// b.k
import a    // circular dependency detected
```

**Break circular dependencies** by extracting shared declarations into a third module that both A and B import:

```kairo
// shared.k
pub fn common_utility() { ... }

// a.k
import shared
// no import b

// b.k
import shared
// no import a
```

Circular dependencies at the module level reflect circular dependencies in the design, restructuring to break the cycle usually improves the architecture.

## Visibility on Top-Level Declarations

All top-level declarations (functions, classes, modules, constants, etc.) default to `pub` when no visibility is written. Use `priv` to restrict to the current file and `prot` for library-internal visibility:

```kairo
pub fn public_api() { ... }
priv fn internal_helper() { ... }
prot fn library_internal() { ... }

pub class Server { ... }
priv class ConnectionPool { ... }

pub eval MAX_CONNECTIONS = 1024
priv static var request_count: i32 = 0
```

See [Imports](/docs/language/imports#visibility-on-imports) for how visibility affects what is re-exported via `pub import`.