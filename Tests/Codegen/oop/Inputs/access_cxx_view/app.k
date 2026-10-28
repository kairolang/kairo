// Corpus for Codegen/oop/access_cxx_view.k: an importer that instantiates
// vault.k's generic function and inlines its inline one in its own TU,
// where the friend declarations in Vault's definition grant them access.
import vault::*

fn main() -> i32 {
    var v = make(5)
    var w = Vault()
    return inline_read(&v) + gen_read(&w, 1) + w.open() - 46
}
