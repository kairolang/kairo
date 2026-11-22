// Fixture of scoped_class_struct_extend.k: records with
// `@set_scoped_allocator`, extended in scoped_class_ext.k.
import inputs::counting_arenas::*

@set_scoped_allocator(Arenas)
pub struct Rec {
    pub var n:    i32
    pub var text: string
}

@set_scoped_allocator(Arenas)
pub class <T> Box {
    pub var items: [T]
    pub fn Box(self) { }
    pub fn add(self, v: T) {
        self.items.push(v)
    }
}
