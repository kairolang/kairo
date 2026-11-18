// oracle for return-vs-void.k
int k(int);
void k(int x) { }   // expected-error: differ only in their return type
