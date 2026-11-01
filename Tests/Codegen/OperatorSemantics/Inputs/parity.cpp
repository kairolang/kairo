// ref_X: plain C++ on inputs where it has no UB. k_X: the exact spelling
// EmitIR (and SequenceLowering) writes for the same Kairo code. parity.py
// compiles both at -O1..-O3 for x86_64 and aarch64 and requires the same
// instruction count, except the allowlisted pairs (semantic differences).
extern "C" {
[[noreturn, gnu::cold]] void kairo_rt_div_zero() noexcept;
int f() noexcept; int g() noexcept; int h(int, int) noexcept; unsigned long idx() noexcept;

#define PAIR_BIN(N, T, U, OP) \
    T ref_##N(T a, T b) { return a OP b; } \
    T k_##N(T a, T b) { return static_cast<T>(static_cast<U>(a) OP static_cast<U>(b)); }
PAIR_BIN(add8, signed char, unsigned, +)  PAIR_BIN(sub8, signed char, unsigned, -)  PAIR_BIN(mul8, signed char, unsigned, *)
PAIR_BIN(add16, short, unsigned, +)       PAIR_BIN(sub16, short, unsigned, -)       PAIR_BIN(mul16, short, unsigned, *)
PAIR_BIN(add32, int, unsigned, +)         PAIR_BIN(sub32, int, unsigned, -)         PAIR_BIN(mul32, int, unsigned, *)
PAIR_BIN(add64, long long, unsigned long long, +) PAIR_BIN(sub64, long long, unsigned long long, -) PAIR_BIN(mul64, long long, unsigned long long, *)
PAIR_BIN(add128, __int128, unsigned __int128, +)  PAIR_BIN(sub128, __int128, unsigned __int128, -)  PAIR_BIN(mul128, __int128, unsigned __int128, *)

#define PAIR_NEG(N, T, U) \
    T ref_##N(T a) { return -a; } \
    T k_##N(T a) { return static_cast<T>(static_cast<U>(0) - static_cast<U>(a)); }
PAIR_NEG(neg8, signed char, unsigned) PAIR_NEG(neg16, short, unsigned) PAIR_NEG(neg32, int, unsigned)
PAIR_NEG(neg64, long long, unsigned long long) PAIR_NEG(neg128, __int128, unsigned __int128)

int ref_shl32(int a, int b) { return a << b; }
int k_shl32(int a, int b) { return static_cast<int>(static_cast<unsigned>(a) << (static_cast<unsigned>(b) & static_cast<unsigned>(31))); }
long long ref_shl64(long long a, long long b) { return a << b; }
long long k_shl64(long long a, long long b) { return static_cast<long long>(static_cast<unsigned long long>(a) << (static_cast<unsigned long long>(b) & static_cast<unsigned long long>(63))); }
int ref_shr32(int a, int b) { return a >> b; }
int k_shr32(int a, int b) { return static_cast<int>((a) >> (static_cast<unsigned>(b) & static_cast<unsigned>(31))); }
long long ref_shr64(long long a, long long b) { return a >> b; }
long long k_shr64(long long a, long long b) { return static_cast<long long>((a) >> (static_cast<unsigned long long>(b) & static_cast<unsigned long long>(63))); }

// p[idx()] += x
void ref_place(int* p, int x) { p[idx()] += x; }
void k_place(int* p, int x) { ({ auto& __kairo_p0 = (p[idx()]); __kairo_p0 = static_cast<int>(static_cast<unsigned>(__kairo_p0) + static_cast<unsigned>(x)); }); }

// s += p[i++] over a fixed bound
int ref_postinc(const int* p) { int s = 0; for (int i = 0; i < 64;) { s += p[i++]; } return s; }
int k_postinc(const int* p) {
    int s = 0;
    for (int i = 0; (i < 64);) {
        (s = static_cast<int>(static_cast<unsigned>(s) + static_cast<unsigned>(p[({ int __kairo_o0 = i; i = static_cast<int>(static_cast<unsigned>(i) + static_cast<unsigned>(1)); __kairo_o0; })])));
    }
    return s;
}

// a summation loop: vectorizes the same
int ref_sum(const int* p, int n) { int s = 0; for (int i = 0; i < n; ++i) { s += p[i]; } return s; }
int k_sum(const int* p, int n) { int s = 0; for (int i = 0; (i < n); (++i)) { (s = static_cast<int>(static_cast<unsigned>(s) + static_cast<unsigned>(p[i]))); } return s; }

// a / 7, a % 7: a constant divisor folds both checks
int ref_div7(int a) { return a / 7; }
int k_div7(int a) { return ({ int __kairo_a0 = (a); int __kairo_b0 = (7); if (__builtin_expect(__kairo_b0 == 0, 0)) ::kairo_rt_div_zero(); (__kairo_b0 == -1) ? static_cast<int>(static_cast<unsigned>(0) - static_cast<unsigned>(__kairo_a0)) : static_cast<int>(__kairo_a0 / __kairo_b0); }); }
int ref_rem7(int a) { return a % 7; }
int k_rem7(int a) { return ({ int __kairo_a0 = (a); int __kairo_b0 = (7); if (__builtin_expect(__kairo_b0 == 0, 0)) ::kairo_rt_div_zero(); (__kairo_b0 == -1) ? static_cast<int>(0) : static_cast<int>(__kairo_a0 % __kairo_b0); }); }

// allowlisted: a runtime divisor's zero and -1 checks are the semantics
int ref_div(int a, int b) { return a / b; }
int k_div(int a, int b) { return ({ int __kairo_a0 = (a); int __kairo_b0 = (b); if (__builtin_expect(__kairo_b0 == 0, 0)) ::kairo_rt_div_zero(); (__kairo_b0 == -1) ? static_cast<int>(static_cast<unsigned>(0) - static_cast<unsigned>(__kairo_a0)) : static_cast<int>(__kairo_a0 / __kairo_b0); }); }

// sequenced: f() - g(), h(f(), g())
int ref_seq_sub() { int a = f(); return a - g(); }
int k_seq_sub() { return ({ const int __kairo_s0 = f(); static_cast<int>(static_cast<unsigned>(__kairo_s0) - static_cast<unsigned>(g())); }); }
int ref_seq_call() { int a = f(); return h(a, g()); }
int k_seq_call() { return ({ const int __kairo_s0 = f(); h(__kairo_s0, g()); }); }

// no_wrap IV: C++'s own ++ and +
void ref_iv(int* p, int n, int k) { for (int i = 0; i < n; ++i) p[i + k] = 0; }
void k_iv(int* p, int n, int k) { for (int i = 0; (i < n); (++i)) { (p[(i + k)] = 0); } }
}
