// Corpus for CLI/Kcc/kcc_visibility.k: a C++ file of api.k's module sees
// its `pub` and `prot` declarations (written or by default), not `priv`.
#include "api.k"

int main() {
#ifdef USE_PRIV
    return mod::api::file_fn();
#else
    return mod::api::open_fn() + mod::api::mod_fn() + mod::api::bare_fn();
#endif
}
