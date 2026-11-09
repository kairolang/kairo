// Corpus for CLI/Kcc/kcc_visibility.k: a C++ file outside api.k's module
// sees its `pub` declarations only.
#include "mod/api.k"

int main() {
#if defined(USE_PROT)
    return mod::api::mod_fn();
#elif defined(USE_BARE)
    return mod::api::bare_fn();
#elif defined(USE_PRIV)
    return mod::api::file_fn();
#else
    return mod::api::open_fn();
#endif
}
