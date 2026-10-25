// widgets.k: the payloads nullable_main.cpp wraps in ::builtin::Nullable.
// Widget prints when a LIVE one is destroyed (a moved-from one has id 0),
// so each value's destruction shows exactly once; Uniq is move-only.
import std::io::println

pub class Widget {
    pub var id: i32
    pub fn Widget(self, id: i32) { self.id = id }
    @copy fn Widget(self, const other: Self) { self.id = other.id }
    fn op delete(self) { if self.id != 0 { println(f"  ~Widget {self.id}") } }
    pub fn op ==(const self, const other: Widget) -> bool { return self.id == other.id }
}

pub class Uniq {
    pub var id: i32
    pub fn Uniq(self, id: i32) { self.id = id }
    @move fn Uniq(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op delete(self) { if self.id != 0 { println(f"  ~Uniq {self.id}") } }
}

/// Nullables built on the Kairo side and handed to the host: `T?` is the
/// same ::builtin::Nullable the host names.
pub fn boxed(id: i32) -> Widget? { return Widget(id) }
pub fn nothing() -> Widget? { return null }
