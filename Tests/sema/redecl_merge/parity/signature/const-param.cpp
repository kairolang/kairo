// oracle for const-param.k
typedef const int cInt;

void f (int);
void f (const int);

void f (int) {  }
void f (cInt) { }   // expected-error: redefinition of f
