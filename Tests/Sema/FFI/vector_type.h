typedef long long v2di __attribute__((vector_size(16)));
typedef long long v2di_u __attribute__((vector_size(16), aligned(1)));
typedef float v4sf __attribute__((ext_vector_type(4)));
v2di mk();
int use(v2di);
v2di both(v2di, v2di);
v2di load(const v2di_u *p);
v4sf mkf();
int usef(v4sf);
