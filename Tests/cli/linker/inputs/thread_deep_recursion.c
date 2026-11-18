#include <pthread.h>
#include <stddef.h>
static volatile char sink;
static int depth(int n) {
    volatile char pad[256];
    pad[0] = (char)n;
    sink = pad[0];
    if (n == 0) return 0;
    return depth(n - 1) + 1;
}
static void *run(void *a) { (void)a; return (void *)(size_t)(depth(3000) == 3000); }
int main(void) {
    pthread_t t; void *r = 0;
    if (pthread_create(&t, 0, run, 0)) return 2;
    pthread_join(t, &r);
    return r ? 0 : 1;
}
