// A `where` group in one file, called from another (main.k). The importer
// binds every call to the group's dispatcher, the one public function; the
// candidates are this file's.
pub fn grade(x: i32) -> i32 where x >= 90 { return 4 }
pub fn grade(x: i32) -> i32 where x >= 80 { return 3 }
pub fn grade(x: i32) -> i32 { return 0 }

pub class Gate {
    pub var open: bool
    pub fn Gate(self, open: bool) { self.open = open }
    pub fn pass(self, n: i32) -> i32 where self.open { return n }
    pub fn pass(self, n: i32) -> i32 { return 0 }
}
