// partial_spec_header/host.cc -- C++ against store.k's header. The partial and
// explicit specializations are declared there, so C++ selects them exactly as
// Kairo did: Store<int*> is the pointer-sized `Store<P*>`, Store<bool> the
// one-byte explicit spec, Store<long> the primary.
#include "store.hh"
static_assert(sizeof(store::Store<int*>) == sizeof(int*));
static_assert(sizeof(store::Store<bool>) == 1);
static_assert(sizeof(store::Store<long>) == sizeof(long));
int probe(const store::Store<int*>& s, const store::Store<bool>& b) {
    return s.tag() + b.tag() + (store::__kairo_ext_Store::read(&s) > 0);
}
#ifdef WRONG
int wrong(const store::Store<int*>& s) { return s.value; }
#endif
