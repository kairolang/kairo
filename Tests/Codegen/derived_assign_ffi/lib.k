// C's `op =` is derived from a transfer constructor with a body, so the
// class carries a placement `::new` in every TU and header that writes it.
// The copy adds 10, so a test can tell a rebuild from a member-wise
// assignment.

pub class C {
    pub var v: i32
    pub fn C(self, v: i32) { self.v = v }
    @copy
    fn C(self, const other: Self) { self.v = other.v + 10 }
    fn op delete(self) { self.v = 0 }
}
