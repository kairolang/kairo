// Only DECLARES Str: a header set that reaches the template through this
// file cannot complete an instance of it.
#pragma once
template <unsigned N> class Str;
template <unsigned N> unsigned fill(Str<N> &);
