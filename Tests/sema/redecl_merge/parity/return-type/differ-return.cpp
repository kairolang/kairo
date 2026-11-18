// oracle for differ-return.k
typedef float Float;
void f(int, Float);
int f(int, Float);   // expected-error: differ only in their return type
