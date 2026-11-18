// A tag hidden by a function of the same name, like POSIX `struct stat` /
// `stat()`: the type is reachable only elaborated.
struct tagval { int a; int b; };
inline int tagval(int x) { return x; }
using tagval_t = struct ::tagval;
