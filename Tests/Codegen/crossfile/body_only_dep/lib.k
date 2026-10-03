pub class Hidden {
    pub var n: i32
}

pub class <T> Box {
    var p: unsafe *void

    pub fn Box(self, p: unsafe *void) { self.p = p }

    // Hidden is named only in this body: sizeof, a cast, a member access.
    pub fn read(self) -> i32 {
        unsafe {
            var h = self.p as unsafe *Hidden
            return h->n + (sizeof(Hidden) as i32)
        }
    }
}
