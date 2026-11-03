#include <cstdio>
#include <cstdlib>
struct Bad { int code; };
long parse(long x) { if (x % 100 == 0) throw Bad{1}; return x * 3; }
int main() { long n = std::atol(std::getenv("N")), sum = 0, fails = 0;
  for (long i = 1; i <= n; ++i) { try { sum += parse(i); } catch (const Bad&) { ++fails; } }
  std::printf("%ld %ld\n", sum, fails); }
