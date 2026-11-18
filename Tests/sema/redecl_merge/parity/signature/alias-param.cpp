// oracle for alias-param.k
typedef int Int;

void g(int x) { }
void g(Int x) { }   // expected-error: redefinition of g
