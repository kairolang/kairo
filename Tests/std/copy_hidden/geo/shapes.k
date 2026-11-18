// Under geo's module.k an unmarked member is `prot`: visible to the files
// of the module, and emitted `public:` in C++, which has no module access.
pub class Pt {
    pub var x: i32
    pub fn Pt(self, x: i32) {
        self.x = x
    }

    fn copy(const self) -> Self {
        return Pt(self.x)
    }
}
