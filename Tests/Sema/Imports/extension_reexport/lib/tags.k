pub interface Tagged { fn tag(const self) -> i32 }
pub fn <T impl Tagged> tag_of(a: T) -> i32 { return a.tag() }
pub interface Marked { fn mark(const self) -> i32 }
pub fn <T impl Marked> mark_of(a: T) -> i32 { return a.mark() }
