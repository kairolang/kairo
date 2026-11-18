// Fails to compile unless the flags under test reached clang.
#ifndef FROM_CXX_DEFINE
#error "--cxx-define did not reach this input"
#endif
#ifndef FROM_CXX_FLAGS
#error "--cxx-flags did not reach this input"
#endif
int flags_ok() { return 1; }
