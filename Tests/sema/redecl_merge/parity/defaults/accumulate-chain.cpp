// oracle for accumulate-chain.k
void f0(int i, int j, int k = 3);
void f0(int i, int j, int k);
void f0(int i, int j = 2, int k);
void f0(int i = 1, int j, int k);
void f0(int i, int j, int k);
void f0(int i = 1, int j, int k);  // expected-error: redefinition of default argument
