// C++ side of abi_registers_x86_64.k. TwinString and TwinVector have the
// layout of Kairo's `string` and `[i32]` and the attribute Kairo gives a
// @relocatable record. The Kairo functions are declared with these types
// under their mangled names, so values cross by value in both directions.

struct __attribute__((trivial_abi)) TwinString {
    const unsigned char* p;
    unsigned long meta;
    TwinString(TwinString&& o) noexcept : p(o.p), meta(o.meta) { o.meta = 0; }
    ~TwinString();
};

struct __attribute__((trivial_abi)) TwinVector {
    int* buf;
    unsigned long len;
    TwinVector(TwinVector&& o) noexcept : buf(o.buf), len(o.len) { o.len = 0; }
    ~TwinVector();
};

// Ownership goes back to Kairo by value (take_*); what C++ holds after a
// move owns nothing.
TwinString::~TwinString() {}
TwinVector::~TwinVector() {}

TwinString make_string(int n) __asm__("_ZN20abi_registers_x86_6411make_stringEi");
TwinVector make_vector(int n) __asm__("_ZN20abi_registers_x86_6411make_vectorEi");
TwinString echo_string(TwinString s) __asm__("_ZN20abi_registers_x86_6411echo_stringEN7builtin6string6stringE");
TwinVector echo_vector(TwinVector v) __asm__("_ZN20abi_registers_x86_6411echo_vectorEN7builtin10containers6vector6VectorIiEE");
unsigned long take_string(TwinString s) __asm__("_ZN20abi_registers_x86_6411take_stringEN7builtin6string6stringE");
unsigned long take_vector(TwinVector v) __asm__("_ZN20abi_registers_x86_6411take_vectorEN7builtin10containers6vector6VectorIiEE");
int vector_sum(const TwinVector& v) __asm__("_ZN20abi_registers_x86_6410vector_sumERKN7builtin10containers6vector6VectorIiEE");

__attribute__((noinline)) TwinString pass_twin_string(TwinString s) { return s; }
__attribute__((noinline)) TwinVector pass_twin_vector(TwinVector v) { return v; }

int main() {
    TwinString s = pass_twin_string(echo_string(pass_twin_string(make_string(7))));
    TwinVector v = pass_twin_vector(echo_vector(pass_twin_vector(make_vector(10))));
    int bad = 0;
    if (vector_sum(v) != 45) bad |= 1;
    if (take_string(static_cast<TwinString&&>(s)) != 47) bad |= 2;
    if (take_vector(static_cast<TwinVector&&>(v)) != 10) bad |= 4;
    return bad;
}
