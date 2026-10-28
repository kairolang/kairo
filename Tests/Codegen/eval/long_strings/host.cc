// C++ host for use.k: lib's long eval string through `#include "lib.k"`
// (EVAL.md §11). Built twice (-DSECOND) and linked with lib.o: the named
// array is an inline variable, one entity across all three objects.
#include "lib.k"

static_assert(::lib::BIG.len == 300);
static_assert(::lib::big_len() == 300);
static_assert(::lib::SHORT.len == 5);

#ifdef SECOND
const unsigned char* second_data() { return ::lib::BIG.data; }
#else
const unsigned char* second_data();
int main() { return (second_data() == ::lib::BIG.data && ::lib::BIG.data[0] == 75) ? 42 : 1; }
#endif
