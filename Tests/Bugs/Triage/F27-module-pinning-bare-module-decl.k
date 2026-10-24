// build: kairo F27-module-pinning-bare-module-decl.k --type-check-only   (expect the bare `module foo` header to parse)
module foo

pub fn answer() -> i32 { return 42 }
