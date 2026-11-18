// oracle for specified-once.k
void f(int i);
void f(int i = 0);
void f(int i = 17);   // expected-error: redefinition of default argument
