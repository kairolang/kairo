// oracle for top-level-const.k
void f(int* x) { }
void f(int* const x) { }   // expected-error: redefinition of f

void g(int* x) { }
void g(const int* x) { }   // ok: two overloads
