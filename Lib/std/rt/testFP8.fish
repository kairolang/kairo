clang++ -std=c++23 -O2 -fno-rtti -fuse-ld=lld -stdlib=libc++ \
    -I build/llvm/include \
    -I Lib/llvm-runtimes/llvm/include \
    Lib/std/rt/Float8Oracle.cc \
    -L build/llvm/lib \
    -lLLVMSupport -lLLVMDemangle \
    -lpthread -lz -lzstd \
    -o f8oracle