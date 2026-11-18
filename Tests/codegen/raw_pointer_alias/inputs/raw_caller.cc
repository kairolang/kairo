// Calls the Kairo-defined ksum through its plain C++ declaration.
#include "raw_caller.hh"
int call_ksum(int *p, decltype(sizeof(0)) n) { return ksum(p, n); }
