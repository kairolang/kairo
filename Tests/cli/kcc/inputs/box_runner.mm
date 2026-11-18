#include "box.k"
#include <iostream>

// --- Minimal GNU ObjC & Blocks ABI stubs (since libobjc isn't in the musl sysroot) ---
extern "C" {
    void * _NSConcreteGlobalBlock[32] = { 0 };
    void * _NSConcreteStackBlock[32]  = { 0 };
    void __objc_exec_class(void *) {}
    int __gnu_objc_personality_v0(...) { return 0; }
}

// 1. Objective-C @protocol and @interface using Kairo generic types
@protocol BoxProcessor
- (void)processBox:(box::Box<int>&)b;
@end

__attribute__((objc_root_class))
@interface GenericTester <BoxProcessor>
+ (void)runStaticTest:(box::Box<int>&)b;
@end

int main() {
    // 2. Objective-C Block (^ syntax) taking a generic Kairo class reference
    //    and calling a generic Kairo member function template
    void (^objcBlock)(box::Box<int>&, double) = ^(box::Box<int>& b, double extra) {
        box::Combined<int, double> res = b.combine<double>(extra);
        std::cout << "Obj-C++ block got Combined: {"
                  << res.first << ", " << res.second << "}" << std::endl;
    };

    {
        box::Box<int> intBox{42};
        objcBlock(intBox, 3.14);
    } // triggers Box::~Box()

    return 0;
}