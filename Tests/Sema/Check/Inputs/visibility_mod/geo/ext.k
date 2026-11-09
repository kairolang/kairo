// Corpus for Sema/Check/visibility_module.k: an `extend` of Shape in
// another file of its module reads Shape's `prot` members.
import shapes

extend shapes::Shape {
    pub fn doubled(const self) -> i32 { return self.area() + self.sides + self.tag }
}
