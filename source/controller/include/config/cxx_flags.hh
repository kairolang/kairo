#ifndef __CXX_FLAGS_H__
#define __CXX_FLAGS_H__

#include <string_view>

namespace cxx::flags {
class CF {
  public:
    std::string_view gcc;
    std::string_view clang;
    std::string_view msvc;
    std::string_view mingw;
};

constexpr CF debugModeFlag{.gcc="-g -g3 -DDEBUG", .clang="-g -g3 -DDEBUG", .msvc="/Zi /DDEBUG", .mingw="-g -g3 -DDEBUG"};
constexpr CF warnAllFlag{.gcc="-Wall", .clang="-Wall", .msvc="/W4", .mingw="-Wall"};
constexpr CF noWarningsFlag{.gcc="-w", .clang="-w", .msvc="/w", .mingw="-w"};
constexpr CF stdC23Flag{.gcc="-std=c23", .clang="-std=c23", .msvc="/std:c23", .mingw="-std:c23"};
constexpr CF stdCXX23Flag{.gcc="-std=c++23", .clang="-std=c++23", .msvc="/std:c++20", .mingw="-std:c++23"};
constexpr CF stdLibAndLinks{
    .gcc="-stdlib=libc++ -lc++ -lc++abi",
    .clang="-stdlib=libc++ -lc++ -lc++abi",
    .msvc="",
    .mingw=""};
constexpr CF optimizationLevel0{.gcc="-O0", .clang="-O0", .msvc="/Od", .mingw="-O0"};
constexpr CF optimizationLevel1{.gcc="-O1", .clang="-O1", .msvc="/O1", .mingw="-O1"};
constexpr CF optimizationLevel2{.gcc="-O2", .clang="-O2", .msvc="/O2", .mingw="-O2"};
constexpr CF optimizationLevel3{.gcc="-O3", .clang="-O3", .msvc="/Ox", .mingw="-O3"};
constexpr CF dryRunFlag{.gcc="-fsyntax-only", .clang="-fsyntax-only", .msvc="/Zs", .mingw="-fsyntax-only"};
constexpr CF optimizationFast{.gcc="-Ofast", .clang="-Ofast", .msvc="/Ox", .mingw="-Ofast"};
constexpr CF optimizationSize{.gcc="-Os", .clang="-Os", .msvc="/O1", .mingw="-Os"};
constexpr CF linkStatic{.gcc="-static", .clang="-static", .msvc="/MT", .mingw="-static"};
constexpr CF linkShared{.gcc="-shared", .clang="-shared", .msvc="/LD", .mingw="-shared"};
constexpr CF positionIndependent{.gcc="-fPIC", .clang="-fPIC", .msvc="/LD", .mingw="-fPIC"};
constexpr CF cxxStandardFlag{.gcc="-xc++", .clang="-xc++", .msvc="/TP", .mingw="-xc++"};  // force c++ mode
constexpr CF noOptimization{.gcc="-fno-inline", .clang="-fno-inline", .msvc="/Ob0", .mingw="-fno-inline"};
constexpr CF defineFlag{.gcc="-D", .clang="-D", .msvc="/D", .mingw="-D"};
constexpr CF includeFlag{.gcc="-I", .clang="-I", .msvc="/I", .mingw="-I"};
constexpr CF linkFlag{.gcc="-l", .clang="-l", .msvc="/link", .mingw="-l"};
constexpr CF linkTimeOptimizationFlag{.gcc="-flto", .clang="-flto", .msvc="/LTCG", .mingw="-flto"};
constexpr CF outputFlag{.gcc="-o", .clang="-o", .msvc="/Fe:", .mingw="-o"};
constexpr CF inputFlag{.gcc="-i", .clang="-i", .msvc="/Fi:", .mingw="-i"};
constexpr CF precompiledHeaderFlag{.gcc="-include", .clang="-include", .msvc="/FI", .mingw="-include"};
constexpr CF preprocessorFlag{.gcc="-E", .clang="-E", .msvc="/P", .mingw="-E"};
constexpr CF compileOnlyFlag{.gcc="-c", .clang="-c", .msvc="/c", .mingw="-c"};
constexpr CF noEntryFlag{.gcc="-nostartfiles", .clang="-nostartfiles", .msvc="/NOENTRY", .mingw="-nostartfiles"};
constexpr CF noDefaultLibrariesFlag{
    .gcc="-nodefaultlibs", .clang="-nodefaultlibs", .msvc="/NODEFAULTLIB", .mingw="-nodefaultlibs"};
constexpr CF noCXXSTDLibrariesFlag{.gcc="-nostdlib++", .clang="-nostdlib++", .msvc="/NOSTDLIB", .mingw="-nostdlib++"};
constexpr CF noCXXSTDIncludesFlag{.gcc="-nostdinc++", .clang="-nostdinc++", .msvc="/NOSTDINC", .mingw="-nostdinc++"};
constexpr CF noBuiltinIncludesFlag{
    .gcc="-nobuiltininc", .clang="-nobuiltininc", .msvc="/NOBUILTININC", .mingw="-nobuiltininc"};
constexpr CF linkLibCFlag{.gcc="-lc", .clang="-lc", .msvc="/DEFAULTLIB:libc", .mingw="-lc"};
constexpr CF linkPathFlag{.gcc="-L", .clang="-L", .msvc="/LIBPATH", .mingw="-L"};
constexpr CF linkDynamicFlag{.gcc="-Wl,-w,-rpath", .clang="-Wl,-w,-rpath", .msvc="/LIBPATH", .mingw="-Wl,-w,-rpath"};
constexpr CF noDiagnosticsFlag{.gcc="",
                               .clang="-fno-diagnostics-show-option",
                               .msvc="/diagnostics:column",
                               .mingw="-fno-diagnostics-show-option"};
constexpr CF noDiagnosticsFixitFlag{.gcc="",
                                    .clang="-fno-diagnostics-fixit-info",
                                    .msvc="/diagnostics:caret",
                                    .mingw="-fno-diagnostics-fixit-info"};
constexpr CF noDiagnosticsShowLineNumbersFlag{.gcc="",
                                              .clang="-fno-diagnostics-show-line-numbers",
                                              .msvc="/diagnostics:caret",
                                              .mingw="-fno-diagnostics-show-line-numbers"};
constexpr CF noDiagnosticsShowOptionFlag{.gcc="",
                                         .clang="-fno-diagnostics-show-option",
                                         .msvc="/diagnostics:caret",
                                         .mingw="-fno-diagnostics-show-option"};
constexpr CF noColorDiagnosticsFlag{.gcc="",
                                    .clang="-fno-color-diagnostics",
                                    .msvc="/diagnostics:caret",
                                    .mingw="-fno-color-diagnostics"};
constexpr CF caretDiagnosticsMaxLinesFlag{.gcc="",
                                          .clang="-fcaret-diagnostics-max-lines=0",
                                          .msvc="/diagnostics:caret",
                                          .mingw="-fcaret-diagnostics-max-lines=0"};
constexpr CF noElideTypeFlag{
    .gcc="-fno-elide-type", .clang="-fno-elide-type", .msvc="/diagnostics:caret", .mingw="-fno-elide-type"};
constexpr CF noOmitFramePointerFlag{.gcc="",
                                    .clang="-fno-omit-frame-pointer",
                                    .msvc="/diagnostics:caret",
                                    .mingw="-fno-omit-frame-pointer"};
constexpr CF enableExceptionsFlag{.gcc="-fexceptions", .clang="-fexceptions", .msvc="/EHsc", .mingw="-fexceptions"};

constexpr CF fullFilePathFlag{.gcc="",
                              .clang="-fdiagnostics-absolute-paths",
                              .msvc="/FC",
                              .mingw="-fdiagnostics-absolute-paths"};
constexpr CF showCaretsFlag{.gcc="-fshow-caret",
                           .clang="-fshow-caret",
                           .msvc="/diagnostics:caret",
                           .mingw="-fshow-caret"};
constexpr CF noErrorReportingFlag{.gcc="-fno-error-report",
                                  .clang="-fno-error-report",
                                  .msvc="/errorReport:None",
                                  .mingw="-fno-error-report"};
constexpr CF SanitizeFlag{.gcc="-fsanitize=address,undefined,pointer-subtract",
                                    .clang="-fsanitize=undefined,bounds,function",
                                    .msvc="/fsanitize=address /RTCc /RTC1 /sdl /RTCu /RTCsu /RTCs",
                                    .mingw="-fsanitize=address,undefined"};
constexpr CF None{.gcc="", .clang="", .msvc="", .mingw=""};
}  // namespace cxx::flags
#endif  // __CXX_FLAGS_H__