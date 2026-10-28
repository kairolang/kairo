# Modules

Kairo's module system maps source files and directories to namespaces. Every `.k` file is a module. A directory containing a `module.k` entry file is a library. Use the `module` keyword to declare namespaces within a file, similar to C++ `namespace`.

See [Imports](/docs/language/imports/) for how to bring names from modules into scope.

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

A module's path is exactly its C++ namespace. `utils/strings.k` in a library named `utils` is `utils::strings` in Kairo and `namespace utils::strings` in the [emitted C++](/docs/language/c-cpp-exposing/#what-a-kairo-declaration-looks-like-in-c); a `module codec { }` block inside it is `utils::strings::codec`. The mapping is fixed by the file's location in its library or [search directory](#search-directories-and-library-names), not by how any importer spelled the import, not by an alias, and not by the directory a library happens to be checked out in. So the C++ name of a declaration is the same in every build of the same tree.

This holds for the files you compile, too. A `.k` named on the command line, or included from C++, is a module like any other, with the path an import of it gets: compiled from `project/`, `utils/io.k` is `utils::io` whether it is compiled, imported or included. So `kcc -c utils/io.k` in one run defines `utils::io::read_file`, and a `main.k` compiled in another run that imports `utils::io` links against it. A path segment that is not a valid C++ identifier is rewritten into one (`operator.k` is `namespace operator_`).

`main` is the exception: a file-scope `fn main` is the program's global `int main` in whatever file it is declared, never in a namespace, and so is the `main` a [script](#scripts) gets. A `main` inside a `module foo { }` block is the ordinary function `foo::main`.

A file outside every [search directory](#search-directories-and-library-names) and every [library](#naming-a-library) has no module path. Its declarations are emitted in a namespace named after the file's stem (`/tmp/scratch.k` becomes `namespace scratch`), its `priv` and `internal` declarations sit in an unnamed namespace and cannot be reached from any other translation unit, and it has no header. A file-scope declaration with no visibility written is `pub`.

Two files under one root that both open `module codec` reopen one namespace, as in C++. Reopening never crosses a root.

## Scripts

A file named on the command line (by `kairo` or `kcc`) that has statements at the top level and no `fn main` is a **script**: its top-level statements are the program, run in order as the body of a `main` the compiler writes. The end of the file returns `0`; a top-level `return` returns from that `main`, and its value, an integer, is the exit status.

```kairo
import std::io::println

fn load() -> i32 { return 42 }

const LIMIT: i32 = 10           // a constant: initialized before anything runs
var answer = load()             // not a constant: runs here, at its line
println(f"start {LIMIT}")
println(f"answer {answer}")
if answer > LIMIT { return 1 }  // exit status 1
```

Every top-level `var`, `const`, `static`, `thread` and `eval` stays a global: functions in the file can name it. A binding whose initializer is a constant (a literal, `sizeof` / `alignof`, or an integer the compiler can evaluate) is initialized before the first statement, as any global is; so are `eval` and `thread` bindings and a binding with no initializer. Every other initializer runs at its own line, in order with the statements around it.

Reading such a variable before its line has run is an error when the compiler can see it: a read in the top-level code above the line, a read in the variable's own initializer, or a top-level call, above the line, of a function in the file that reads it on every path. Anywhere the order cannot be seen (in a function called through another function, a method, a closure), the read is checked when it runs, and the program stops with `script variable 'x' used before its line ran (file:line)`, in every build mode. Values whose line has run are destroyed when the program ends, in reverse order, after the last statement and on every `return`.

A file with `fn main` cannot also have top-level statements, and only the file the program starts from runs them: a top-level statement in an imported module, or in a `.k` file a C++ file includes, is an error. Every command-line input may be a script, but two scripts linked into one program are an error naming both (compiling them with `-c` and no link is fine). A `jump!` at the top level may not cross a line whose initializer runs there. See [Diagnostics](/docs/language/diagnostics/#scripts) for the errors, and [Implementation Status](/docs/status/) for what is not supported yet.

## Library Entry Files

A directory with a `module.k` file is a **library**. The entry file controls what the library exports publicly:

```kairo
// utils/module.k
pub import strings    // re-export utils/strings.k
pub import io         // re-export utils/io.k
priv import internal  // NOT re-exported (implementation detail)
```

Imports inside `module.k` are **relative to the directory**. [`pub import strings`](/docs/language/imports/#re-export-pattern) resolves to `utils/strings.k`.

Consumers of the library see only the public API:

```kairo
import utils

utils::strings::trim("  hello  ")    // from utils/strings.k
utils::io::read_file("data.txt")     // from utils/io.k
// utils::internal::...              // compile error: not exported
```

The library entry file is the public face of the library. Use it to re-export submodules, hide internal organization, and present a clean API boundary.

## Search Directories and Library Names

The compiler finds modules in **search directories**: the working directory, and every directory given with `-I`. A search directory has no name of its own. A file under one is its path relative to that directory, so with `kairo main.k -I vendor`, `./math.k` is `math` and `vendor/text/utf8.k` is `text::utf8`. The folder name `vendor` is not part of either path.

`-I` is also Clang's `-I`. The same directory is searched for the headers of C and C++ inputs, for [`ffi` header imports](/docs/language/imports/#ffi-header-imports), and for [`#include "foo.k"`](/docs/language/c-cpp-toolchain/#how-kcc-works) in C++, so a `.k` file can sit next to the headers that include it. `--cxx-include` and `--ffi-include` add a directory for Clang only.

### Naming a library

A library gets a name from its `module.k`. When the first declaration in `module.k` is a bare `module` followed by a module path, that path is the library's name, whatever the folder is called:

```kairo
// vendor/geometry/module.k
module geo

pub import shapes
```

```kairo
import geo              // vendor/geometry/module.k
import geo::shapes      // vendor/geometry/shapes.k
```

Every file under the directory is `geo::<directories>::<file>`, whether it is imported, compiled on its own (from any directory, including the library's own or one inside it), or included from C++: the compiler finds a file's library by walking up from the file to the nearest `module.k` that names one, past the working directory and any `-I` directory. So `kcc -c inner/x.k` run in `vendor/geometry`, `kcc -c x.k` run in `vendor/geometry/inner`, and an importer anywhere all agree that the file is `geo::inner::x`. A name can have several segments (`module acme::tools`).

The standard library's name comes from the compiler, which registers `Lib/std` as `kairo::std` and lets source write `std` to reach it. `Lib/std/module.k` says `module kairo::std` as well, and the compiler checks that the two agree.

The bare `module name` declaration is only allowed in a `module.k`, and only as its first declaration, which is the one the compiler reads the name from. Anywhere later in a `module.k`, or a second time, it is an error. In any other file it is an error that points at the block form, `module name { ... }`, which declares a [namespace](#module-namespaces) inside the file.

The compiler looks for named libraries in each search directory and in its immediate subdirectories. It does not search deeper, because a search directory can be a whole repository. A `module.k` deeper in the tree still names the files under it, but its library cannot be imported by name from outside it. Inside it, its files import each other by the library's name (`import geo::shapes`) or by their path in it (`import shapes`), as in any library.

Import a library by its name. A file in a library never falls back to the search directories: a library does not depend on what one build's command line contains.

> [!NOTE]
> Older compilers named a directory after its folder (`-I ~/foo` was library `foo`) or with `-I name=dir`. Both are gone. An `-I` with an `=` that is not an existing directory is now an error that says where the name goes: put `module name` as the first line of that directory's `module.k`.

### Collisions

One module path must mean one file, so the compiler never chooses between two files that claim the same path:

- Two libraries with the same name are an error (R018E) before anything is compiled. Rename one library's `module` declaration.
- The same path in two search directories is an error (R017E) at the import that reaches them. With `./a.k` and `inc/a.k` under `-I inc`, both files are module `a`, so `import a` reports both. Remove or rename one, or give one directory a `module.k` that names it as a library.
- Two files that end up with one module path any other way are an error (R018E) that names both: a deeper `module.k` claiming a name another library already has, or two files given on one command line from two search directories (`kairo a.k inc/a.k -I inc`, rejected before either is compiled, since both would be module `a` and write one object).

Giving the same directory twice (`-I inc -I inc`, or a symlink and the directory it points to) is not a collision, and neither is an `-I` naming the standard library's own directory.

Because a search directory has no name, several `-I .../include` directories do not collide with each other.

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

[**Core language primitives**](/docs/language/primitives/) (`i32`, `string`, `bool`, `[T]`, etc.) and **built-in syntax** (`if`, `for`, `match`, etc.) are always available without any import. Only **standard library functions and types** (`std::println`, `std::parse`, `std::Shared`, etc.) require an explicit import.

See [Imports](/docs/language/imports/) for import syntax and the `pub import` pattern for re-exporting.

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
priv static request_count: i32 = 0
priv thread request_id: u64 = 0
```

See [Imports](/docs/language/imports/#visibility-on-imports) for how visibility affects what is re-exported via `pub import`.
## See also

- [Imports](/docs/language/imports/)
- [Re-export Pattern](/docs/language/imports/#re-export-pattern)
- [Using Kairo in C++](/docs/language/c-cpp-exposing/)
- [A Note on C++ Modules](/docs/language/c-cpp/#a-note-on-c-modules)
- [Macro Scoping](/docs/language/macros/#scoping)
- [Class Visibility](/docs/language/classes/#visibility)
