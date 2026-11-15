// Corpus for Codegen/generics/fn_spec_xfile.k: a C++ host including sp.k
// calls the specialization through the primary's name.
#include "sp.k"

int main() {
    return sp::pick<int>() * 10 + sp::pick<char>() - 21;
}
