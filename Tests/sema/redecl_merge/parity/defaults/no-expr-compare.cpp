// oracle for no-expr-compare.k
int rng() { return 4; }

void a(int x = 1);
void a(int x = 1) { }   // expected-error: redefinition of default argument

void b(int x = rng());
void b(int x = rng()) { }   // expected-error: redefinition of default argument
