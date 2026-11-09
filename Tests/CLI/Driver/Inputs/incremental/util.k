// The imported module of Tests/CLI/Driver/incremental_*.k. Each test copies
// this directory, edits one thing with sed, and rebuilds against the same
// --cache-dir. The `// FIELD` line is the private-field edit's anchor.

pub var G: i32 = 0

pub class Box {
    pub var a: i32 = 1
    priv var b: i32 = 2
    // FIELD
    pub fn get(self) -> i32 { return self.a + self.b }
}

pub fn <T> ident(x: T) -> T { return x }

pub fn calc(x: i32) -> i32 { return x * 3 }

pub fn unused(x: i32) -> i32 { return x * 2 }
