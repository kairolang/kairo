/* C half of the native-inputs fixture: calls into the C++ half. */
int add(int a, int b);

int main(void) { return add(40, 2); }
