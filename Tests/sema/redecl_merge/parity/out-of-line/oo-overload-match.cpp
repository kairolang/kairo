// oracle for oo-overload-match.k
class C {
public:
  void bump();
  void bump(int n);
};

void C::bump() { }
void C::bump(int n) { }
