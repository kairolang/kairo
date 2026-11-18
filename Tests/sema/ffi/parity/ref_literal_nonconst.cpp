// oracle for ref_literal_nonconst.k
#include "../ref_overload.h"

void use_literal() {
    int r = takes_ref(1);   // error: a prvalue does not bind int&
    (void)r;
}
