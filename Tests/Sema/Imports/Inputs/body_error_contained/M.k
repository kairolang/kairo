// One undeclared name in one method BODY; every signature here must still
// resolve for an importer.
pub enum FlagKind derives u8 { Bool, Str }
pub class C {
    fn <eval T: FlagKind> define(self, key: string, dfl: bool) -> unsafe *Self {
        return unsafe &self;
    }
    fn h(self, n: usize) -> i32 { return 0; }
    fn g(self) {
        nowhere::print("x");
    }
}
pub fn <T> free_alloc(n: usize) -> i32 { return 0; }
