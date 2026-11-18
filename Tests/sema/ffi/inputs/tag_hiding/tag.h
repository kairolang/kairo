// The tag half of glibc's split: <sys/time.h> declares the struct and the
// functions that take it; the variable lives in var.h, as in <time.h>.
struct timezone { int minuteswest; int dsttime; };
inline struct timezone* get_tz() { static struct timezone z = {5, 0}; return &z; }
inline int tz_minutes(struct timezone* tz) { return tz ? tz->minuteswest : -1; }
