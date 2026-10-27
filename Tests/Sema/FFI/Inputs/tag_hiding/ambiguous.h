// Two ORDINARY names in one C++ scope through inline namespaces: legal to
// declare, ambiguous to use -- clang reports it at the use, never here.
inline namespace v1 { extern int dup; }
inline namespace v2 { typedef int dup; }
