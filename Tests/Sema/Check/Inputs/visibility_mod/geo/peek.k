// Corpus for Sema/Check/visibility_module.k: `priv` stays the file's own,
// even inside the module.
import shapes

fn main() -> i32 {
    var s = shapes::Shape()
    return shapes::secret() + s.inner()
}
