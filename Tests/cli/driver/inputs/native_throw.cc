// Compiles under clang's C++ default (exceptions on); -fno-exceptions must
// turn that off for this input.
int may_throw(int x) {
    if (x < 0) { throw x; }
    return x;
}
