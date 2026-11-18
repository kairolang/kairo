#pragma once
template <unsigned N> struct Slot { int v = N; };
Slot<64> make_slot();
void take_slot(Slot<64> s);
