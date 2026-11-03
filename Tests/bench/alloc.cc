// Built twice by bench-run.fish: plain (new/delete) and -DUSE_MALLOC
// (malloc + placement new + free). The asm barrier keeps clang from eliding
// the allocation.
#include <cstdlib>
#include <new>
struct P2 { long a, b; P2(long a, long b) : a(a), b(b) {} };
volatile long sink;
int main() {
    int n = atoi(getenv("N"));
#if defined(USE_MALLOC)
    for (int i = 0; i < n; i++) { P2* p = (P2*)malloc(sizeof(P2)); if (!p) abort(); new (p) P2(i, 2); asm volatile("" :: "r"(p) : "memory"); sink = sink + p->a; free(p); }
#else
    for (int i = 0; i < n; i++) { P2* p = new P2(i, 2); asm volatile("" :: "r"(p) : "memory"); sink = sink + p->a; delete p; }
#endif
}
