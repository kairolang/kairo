// build: kairo f27_module_pinning_bare_module_decl.k --type-check-only   (expect the bare `module foo` header to parse)
module foo

pub fn answer() -> i32 { return 42 }
