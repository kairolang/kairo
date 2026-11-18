// Corpus for codegen/generics/member_spec_xmod.k: a C++ host including
// spec.k calls the class's member template; the specializations run.
#include "spec.k"

int main() {
    lib::G<short> a;
    lib::G<unsigned char> b;
    return a.m<int>() * 100 + a.m<long>() * 10 + b.m<int>() - 214;
}
