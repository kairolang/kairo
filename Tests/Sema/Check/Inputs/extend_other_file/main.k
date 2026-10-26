import point::Point
import show::Show
extend Point { pub fn twice(const self) -> i32 { return self.x * 2 } }
extend Point impl Show { pub fn show(const self) -> i32 { return self.x } }

fn main() -> i32 { return 0 }

// Corpus for Sema/Check/extend_other_file.k (the checks there name lines 3
// and 4 of this file; keep this comment below the code).
