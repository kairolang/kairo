// A tag and the function that hides it, in ONE header (<sys/stat.h>'s shape).
struct st { int x; };
inline int st(int v) { return v + 1; }

// One entity under one name.
typedef struct pair { int a; int b; } pair;
