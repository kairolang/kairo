// oracle for local_ops.k
#include "../operators.h"

void use_ops() {
    vm::V a = make_v();
    vm::V b = a + a;
    vm::V c = 2 * a;
    vm::V n = -a;
    bool  e = a == b;
    (void)c; (void)n; (void)e;
}
