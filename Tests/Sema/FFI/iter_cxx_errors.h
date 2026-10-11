// Corpus for iter_cxx_errors.k.
#pragma once
namespace ie {
struct OnlyBegin { int* begin(); };       // a member begin with no end
struct Free { int v[2]; };                // free begin/end...
inline int* begin(Free& f) { return f.v; }
inline int* end(Free& f) { return f.v + 2; }
struct Plain { int x; };                  // ...which do not take a Plain
}
