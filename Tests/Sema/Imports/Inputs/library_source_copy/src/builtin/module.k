// A source copy of builtin. The generic is legal only in library code
// (SC198E elsewhere), so it fails if this copy is checked as a user file.
module builtin

pub import extra::*

pub fn <T: type> ident(x: T) -> T {
    return x
}
