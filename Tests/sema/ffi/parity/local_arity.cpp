// oracle for local_arity.k
#include "../struct.h"

int use_arity() {
    return point_sum();  // expected-error: too few arguments to function call
}
