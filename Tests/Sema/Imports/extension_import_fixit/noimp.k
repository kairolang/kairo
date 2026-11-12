// A file that opens with a comment block and imports nothing.
// The fix-it adds the import after the block, not inside its first line.

pub fn six() -> i32 { return 3.twice() }
