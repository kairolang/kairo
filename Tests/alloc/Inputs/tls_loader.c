// Loads the library named by argv[1] with dlopen and calls its tls_bump
// three times: the thread-local counter must read 3. Exit codes: 1 dlopen
// failed (dlerror on stderr), 2 no symbol, 3 wrong count.
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 2) return 1;
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    long (*bump)(void) = (long (*)(void))dlsym(h, "tls_bump");
    if (!bump) return 2;
    bump();
    bump();
    return bump() == 3 ? 0 : 3;
}
