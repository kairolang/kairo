// Corpus for Sema/Check/visibility_module.k: another file of the module
// uses every `prot` declaration of shapes.k, written and unmarked: clean.
import shapes
import ext

fn main() -> i32 {
    var s = shapes::Shape()
    return shapes::scale() + shapes::unit() + s.area() + s.sides + s.tag + s.doubled()
}
