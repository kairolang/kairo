// Fixture of scoped_class_struct_extend.k: `extend`s, in a file of their
// own, of the records scoped_class_rec.k gives an arena.
import inputs::counting_arenas::*
import inputs::scoped_class_rec::*

extend Rec {
    pub fn fill_far(self) -> usize {
        self.text.push_str(
            "from another file .....................................................",
        )

        return cur
    }
}

extend <T> Box<T> {
    pub fn add_far(self, v: T) -> usize {
        self.items.push(v)
        return cur
    }
}
