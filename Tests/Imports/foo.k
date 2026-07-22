// foo.k  middle module for the TRANSITIVITY WALL (case 6).
//   `priv import bar::*` is pure topology: a private import edge is NOT an
//   export. An importer of foo must NOT see bar's names through foo; it must
//   see foo's OWN decl `sub`. This already holds: ImportResolution folds a
//   source module's own frozen decls, never what it merely imported, so bar's
//   names cannot leak through foo.

priv import bar::*

pub fn sub(a: i32, b: i32) -> i32 {
    return a - b
}
