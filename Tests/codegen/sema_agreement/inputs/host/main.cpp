// The C++ host of Tests/codegen/sema_agreement/host_include.k.
#include "lib.k"

int main() { return lib::twice<int>(1) - 3; }
