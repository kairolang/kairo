// Corpus for Sema/Check/visibility_file.k: the same names reached bare,
// through `import ...::*` (NameResolution's R047E, not AccessCheck).
import lib::*

fn main() -> i32 {
    return open_fn() + priv_fn() + prot_fn() + bare_fn()
}
