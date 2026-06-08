#!/usr/bin/env fish
clang++ -std=c++23 -stdlib=libc++ \
  -Ibuild/llvm/include \
  -ILib/llvm-runtimes/llvm/include \
  -ILib/llvm-runtimes/clang/include \
  -ILib/llvm-runtimes/lld/include \
  -Ibuild/llvm/tools/clang/include \
  -Lbuild/llvm/lib \
  -fno-lto -Wno-parentheses-equality -Wno-return-type \
  -fuse-ld=lld \
  test_clang.cc \
  -llldMinGW -llldCOFF -llldELF -llldCommon \
  -lclang-cpp -lLLVM \
  -g -Wl,-rpath,build/llvm/lib \
  -o test_clang

if test $status -ne 0
    exit $status
end

./test_clang

if test $status -ne 0
    exit $status
end

./prog

echo "exit code: $status"