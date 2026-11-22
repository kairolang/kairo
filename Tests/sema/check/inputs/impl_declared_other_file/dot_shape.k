import shape::Shape
import dot::Dot
import dot_name
extend Dot impl Shape { }

// Corpus for sema/check/impl_declared_other_file.k: an `extend ... impl`
// in another file, met by Dot's own member and by an extension member of a
// file this one imports.
