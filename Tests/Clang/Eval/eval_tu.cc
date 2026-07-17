// eval_tu.cpp - stands in for the generated TU
#include <array>
#include <string_view>
#include <cstring>

struct Version { int major, minor, patch; std::array<char,16> tag; std::size_t tag_len; };
consteval Version parse_version(std::string_view s) { /* ... */ }

extern "C" {
  unsigned long __kairo_sizeof() { return sizeof(Version); }

  // path under test: raw blit, padding zeroed
  void __kairo_raw(const char* in, unsigned char* out) {
      Version v; std::memset(&v, 0, sizeof v);
      v = parse_version(in);
      std::memcpy(out, &v, sizeof v);
  }

  // oracle: structured field dump
  void __kairo_dump(const char* in, long* fields, char* tag, unsigned long* tl) {
      Version v = parse_version(in);
      fields[0]=v.major; fields[1]=v.minor; fields[2]=v.patch;
      std::memcpy(tag, v.tag.data(), 16); *tl = v.tag_len;
  }
}

/*
# macOS
clang++ -std=c++20 -O2 -dynamiclib -fPIC \
    Tests/Clang/Eval/eval_tu.cc -o eval_tu.dylib

# Linux
clang++ -std=c++20 -O2 -shared -fPIC \
    Tests/Clang/Eval/eval_tu.cc -o eval_tu.so
*/