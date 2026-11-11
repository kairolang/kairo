#pragma once
typedef int (*nfp_cb_t)(int);
inline int nfp_run(nfp_cb_t cb, int x) { return cb ? cb(x) : -1; }
inline int nfp_twice(int x) { return x * 2; }
