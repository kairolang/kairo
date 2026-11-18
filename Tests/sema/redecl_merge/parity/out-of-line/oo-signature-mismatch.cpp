// oracle for oo-signature-mismatch.k
class C {
public:
  void bump();
};

void C::bump(int x) { }   // expected-error: does not match any declaration
