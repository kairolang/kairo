# Modules

Kairo's module system maps source files and directories to namespaces. Each `.k` file is a module.
A directory containing a `.k` file with the same name as the directory is a library its entry
file re-exports contents from sibling files in the directory.

---

## File-to-Module Mapping

Each `.k` file is a module named after the file (without the extension). A directory with an
entry file forms a library:

```
project/
  main.k
  math/
    math.k        <- library entry for "math"
    vector.k
    matrix.k
    internal/
      helpers.k
```

```kairo
// main.k
import math              // imports the math library (math/math.k)
import math::vector      // imports math/vector.k specifically
import math::matrix      // imports math/matrix.k specifically
```

The library entry file (`math/math.k`) controls what the library exports. Files in the directory
are accessible via `libraryname::filename`.

---

## Import Syntax

Imports bring names from other modules into the current scope:

```kairo
// Import an entire module/library
import math

// Import a specific item
import math::Vector3

// Import multiple items
import math::{Vector3, Matrix4, cross_product}

// Import everything from a module (wildcard)
import math::*

// Rename on import
import math as m
import math::{Vector3 as Vec3, Matrix4 as Mat4}

// Source file only (disallow library resolution)
import module math
```

### `import module`

`import module` restricts the import to source files only it will not resolve library entry
files. Use this when you need a specific file and want to avoid ambiguity with a library of the
same name.

---

## Visibility on Imports

Imports can have visibility modifiers. A `priv import` brings names into the current file but does
not re-export them to files that import the current module:

```kairo
// network.k
pub import std::collections     // re-exported to anyone importing network
priv import std::internal       // only available in this file
prot import std::platform       // available to files in the same directory/library
```

By default, imports are public anything you import is visible to modules that import you. Use
`priv import` for implementation details that should not leak.

---

## Top-Level Declarations

All top-level declarations (functions, classes, structs, enums, variables) can have visibility
modifiers:

```kairo
pub fn public_api() { ... }
priv fn internal_helper() { ... }
prot fn library_internal() { ... }

pub class Server { ... }
priv class ConnectionPool { ... }

pub eval MAX_CONNECTIONS = 1024
priv static var request_count: i32 = 0
```

The default visibility for top-level declarations is `pub`. Use `priv` to restrict access to the
current file and `prot` to restrict access to the current file and modules that are in the same
directory or library.

---

## Modules (Namespaces)

The `module` keyword creates a namespace within a file. It is equivalent to C++'s `namespace`:

```kairo
module serialization {
    pub fn to_json(data: Config) -> string { ... }
    pub fn from_json(input: string) panic -> Config { ... }

    priv fn escape_string(s: string) -> string { ... }
}

serialization::to_json(my_config)
```

### Anonymous modules

A module without a name creates a scope for grouping declarations without introducing a named
namespace:

```kairo
module {
    // declarations here are scoped but not namespaced
    var internal_state: i32 = 0
}
```

### Module visibility

Modules themselves can have visibility modifiers:

```kairo
pub module api {
    // accessible from anywhere
    fn handle_request(req: Request) -> Response { ... }
}

priv module cache {
    // only accessible within this file
    var store: {string: Data} = {}
    fn lookup(key: string) -> Data? { ... }
}

prot module platform {
    // accessible within this file and sibling modules in the same library
    fn detect_os() -> string { ... }
}
```

The default module visibility is `pub`.

---

## Module Extending

A module can be extended across multiple files. The second file imports the module and reopens it
to add more declarations:

```kairo
// encoding.k
pub module codec {
    pub fn encode_base64(data: [byte]) -> string { ... }
    pub fn decode_base64(input: string) -> [byte] { ... }
}
```

```kairo
// compression.k
import encoding::codec

pub module codec {
    // visibility must match the original declaration
    pub fn compress(data: [byte]) -> [byte] { ... }
    pub fn decompress(data: [byte]) -> [byte] { ... }
}
```

```kairo
// main.k
import compression

compression::codec::encode_base64(data)   // defined in encoding.k
compression::codec::compress(data)         // defined in compression.k
```

Reopening a module with a different visibility than the original is a compile error.

---

## Scope Resolution (`::`)

The `::` operator resolves names across all scoping contexts:

| Context | Example |
|---|---|
| Module access | `std::println(...)` |
| Class static members | `Counter::count` |
| Enum variants | `Direction::North` |
| Nested types | `Packet::Header` |
| Base class method calls | `Base::method(self)` |
| Library submodules | `math::vector::cross_product(...)` |

`::` works uniformly across all contexts. There is no separate syntax for module access vs type
member access.

---

## The Standard Library (`std`)

`std` is not automatically imported. The user must import it explicitly:

```kairo
import std

std::println("hello")
std::create<i32>(42)
```

Individual items can be imported directly:

```kairo
import std::{println, create}

println("hello")
```

> [!NOTE]
> The core language primitives (`i32`, `string`, `bool`, etc.) and built-in syntax (`if`, `for`,
> `match`, etc.) are available without any import. Only standard library functions and types
> (`std::println`, `std::Error`, `std::Shared`, etc.) require an import.

---

## C/C++ Header Imports

C and C++ headers are imported via the `ffi` keyword. The header is parsed by the compiler and all
exported declarations become available:

```kairo
ffi "c++" import "graphics.hh"
ffi "c" import "legacy_api.h"
```

By default, all declarations from the header are dumped into the current namespace (matching C++
`#include` behavior). Use `as` to namespace the import:

```kairo
ffi "c++" import "graphics.hh" as gfx

gfx::create_window(800, 600)
gfx::RenderContext()
```

### C++ `std` namespace collision

If a C++ header defines names in the `std` namespace, those names collide with Kairo's `std`
module. The C++ standard library is accessible through the `libcxx` module:

```kairo
import std                          // Kairo standard library
import libcxx::vector               // C++ std::vector
import libcxx::iostream::{cout, endl}

std::println("Kairo's println")
cout << "C++ cout" << endl
```

Inside `inline "c++"` blocks, `std::` resolves to Kairo's standard library (the block emits inside
`namespace kairo`). Use `libcxx::` imports for C++ standard library types.

See [C/C++ Interop](/docs/language/c-c++) for the full FFI model.

---

## Circular Imports

Circular imports are a compile error. If module A imports module B and module B imports module A,
the compiler rejects the cycle:

```kairo
// a.k
import b        // compile error if b.k imports a

// b.k
import a        // circular dependency
```

Break circular dependencies by extracting shared declarations into a third module that both A and
B import.

---

## Library Entry Files

A directory with a `.k` file matching the directory name acts as a library. The entry file
controls exports:

```kairo
// network/network.k (library entry)
import tcp       // network/tcp.k
import udp       // network/udp.k
priv import dns  // network/dns.k not re-exported

// Anything defined or publicly imported here is accessible via "import network"
pub fn connect(host: string, port: i32) -> Connection { ... }
```

```kairo
// main.k
import network

network::connect("localhost", 8080)   // from network.k
network::tcp::listen(8080)            // from network/tcp.k
// network::dns::resolve("...")       // compile error: dns is priv imported
```

---

## Summary

```kairo
// File imports
import math
import math::Vector3
import math::{Vector3, Matrix4}
import math::*
import math as m

// Visibility on imports
pub import std::collections
priv import std::internal

// Modules (namespaces)
module serialization {
    pub fn to_json(data: Config) -> string { ... }
}

// Module extending
import encoding::codec
pub module codec {
    pub fn compress(data: [byte]) -> [byte] { ... }
}

// C++ header import with namespace
ffi "c++" import "engine.hh" as engine
engine::initialize()

// Standard library
import std
std::println("hello")

// Scope resolution (uniform)
std::println(...)          // module
Counter::count             // static member
Direction::North           // enum variant
Packet::Header { ... }     // nested type
```
