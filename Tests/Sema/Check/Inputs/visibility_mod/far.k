// Corpus for Sema/Check/visibility_module.k: a file outside geo/ reaches
// none of geo's `prot` declarations, written or unmarked.
import geo::shapes

fn main() -> i32 {
    var s = shapes::Shape()
    return shapes::scale() + shapes::unit() + s.area() + s.sides + s.tag
}
