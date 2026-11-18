// oracle for oo-double-def.k
class C {
public:
  void bump();
};

void C::bump() { }
void C::bump() { }   // expected-error: redefinition
