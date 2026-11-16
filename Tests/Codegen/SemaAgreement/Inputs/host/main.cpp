// The C++ host of Tests/Codegen/SemaAgreement/host_include.k.
#include "lib.k"

int main() { return lib::twice<int>(1) - 3; }
