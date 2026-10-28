// Corpus for Codegen/oop/access_cxx_view.k: a C++ host including vault.k.
// It calls the module's inline and generic functions, which read Vault's
// private members as friends, and sees those members private itself.
#include "vault.k"

template <class V> constexpr bool reads_secret = requires(V v) { v.secret; };
template <class V> constexpr bool calls_peek   = requires(const V v) { v.peek(); };
template <class V> constexpr bool reads_shared = requires(V v) { v.shared; };
static_assert(!reads_secret<vault::Vault>, "a priv field is private to a C++ host");
static_assert(!calls_peek<vault::Vault>, "a priv method is private to a C++ host");
static_assert(!reads_shared<vault::Vault>, "a prot field is protected to a C++ host");
static_assert(__is_constructible(vault::Vault), "the pub constructor stays public");

#ifdef POKE
int poke(vault::Vault& v) { return v.secret; }
#endif

int main() {
    vault::Vault v = vault::make(5);
    vault::Vault w;
    return vault::inline_read(&v) + vault::gen_read(&w, 1) + w.open() - 46;
}
