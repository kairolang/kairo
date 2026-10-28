// Imported by use.k: an eval binding of an eval class, read from another
// module whose initializer Sema has already lowered.
pub struct Config {
    pub var size: i32
    pub var label: string
    eval fn Config(self, size: i32, label: string) {
        self.size = size
        self.label = label
    }
}

pub eval SMALL = Config(4, "small")

pub class <eval C: Config> Widget {
    fn Widget(self) { }
    fn size(const self) -> i32 { return C.size }
}
