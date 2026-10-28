import point::Point
pub interface Show { fn show(const self) -> i32 }
pub interface Size { fn size(const self) -> i32 }
extend Point impl Show { pub fn show(const self) -> i32 { return self.x } }
extend Point impl Size { pub fn size(const self) -> i32 { return self.y } }

// Corpus for Sema/Check/access_ext_other_file.k (its checks name lines 4
// and 5 of this file; keep this comment below the code): the interfaces'
// file, where `extend ... impl` may sit, but not read Point's privates.
