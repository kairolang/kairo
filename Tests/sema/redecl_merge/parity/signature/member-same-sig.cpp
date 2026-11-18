// oracle for member-same-sig.k
class C {
public:
  void bump(int x) { }
  void bump(int x) { }   // expected-error: redefinition
};
