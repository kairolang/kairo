// Corpus for volatile.k: a volatile field, and one parameter that keeps the
// qualifier and one that would drop it.
#pragma once

struct R { volatile int reg; };

void poke(volatile int* p);
void peek(int* p);
