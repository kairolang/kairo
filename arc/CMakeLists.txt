cmake_minimum_required(VERSION 3.14)
project(kairo-lang)

# Set C++ standard
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Check for LLVM environment variables
# if(NOT DEFINED ENV{LLVM_DIR})
#     message(FATAL_ERROR "LLVM_DIR is not set. Please provide the path to the LLVM build directory.")
# endif()
#
# if(NOT DEFINED ENV{LLVM_SRC_DIR})
#     message(FATAL_ERROR "LLVM_SRC_DIR is not set. Please provide the path to the LLVM source directory.")
# endif()
#
# # Set LLVM paths from environment variables
# set(LLVM_DIR $ENV{LLVM_DIR})
# set(LLVM_SRC_DIR $ENV{LLVM_SRC_DIR})
# set(LLVM_TABLEGEN $ENV{LLVM_TABLEGEN})
# set(CLANG_TABLEGEN $ENV{CLANG_TABLEGEN})

# Include LLVM directories
# include_directories(${LLVM_SRC_DIR}/llvm/include)
# include_directories(${LLVM_SRC_DIR}/clang/include)
# include_directories(${LLVM_DIR}/include)
# include_directories(${LLVM_SRC_DIR}/mlir/include)

# Link LLVM libraries
# link_directories(${LLVM_DIR}/lib)

# Automatically include all .cc files in the source directory and its subdirectories
file(GLOB_RECURSE SOURCE_FILES "source/*.cc")

# Define the executable
add_executable(kairo ${SOURCE_FILES})

# Set runtime output directories
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_definitions(kairo PRIVATE DEBUG)
    target_compile_options(kairo PRIVATE -g -O0 -MDd)
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_DEBUG ${CMAKE_BINARY_DIR}/bin/Debug)
else()
    target_compile_definitions(kairo PRIVATE NDEBUG)
    target_compile_options(kairo PRIVATE -O3 -MD)
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE ${CMAKE_BINARY_DIR}/bin/Release)
endif()

# Platform-specific settings
if(APPLE)
    # Use the default macOS linker and clang settings
    # target_link_libraries(kairo PRIVATE clang clang-cpp c++ c++abi)
    target_compile_options(kairo PRIVATE -stdlib=libc++)
else()
    # Use lld for non-Apple platforms
    # target_compile_options(kairo PRIVATE -fuse-ld=lld)
    # target_link_libraries(kairo PRIVATE clang clang-cpp libc++ libc++abi)
    target_compile_options(kairo PRIVATE -stdlib=libc++ -fno-rtti)
    # target_link_options(kairo PRIVATE -stdlib=libc++ -L${LLVM_DIR}/lib -lc++abi -Wl,-rpath,${LLVM_DIR}/lib)
endif()

# Find llvm-config and include its directories
# find_program(LLVM_CONFIG llvm-config HINTS ${LLVM_DIR}/bin)
#
# if(LLVM_CONFIG)
#     execute_process(COMMAND ${LLVM_CONFIG} --includedir OUTPUT_VARIABLE LLVM_INCLUDEDIR OUTPUT_STRIP_TRAILING_WHITESPACE)
#     execute_process(COMMAND ${LLVM_CONFIG} --libdir OUTPUT_VARIABLE LLVM_LIBDIR OUTPUT_STRIP_TRAILING_WHITESPACE)
#     include_directories(${LLVM_INCLUDEDIR})
#     link_directories(${LLVM_LIBDIR})
# else()
#     message(FATAL_ERROR "llvm-config not found!")
# endif()

# Additional include directories if needed
# include_directories(${LLVM_SRC_DIR}/clang/include)
# include_directories(${LLVM_SRC_DIR}/llvm/include)
# include_directories(${LLVM_SRC_DIR}/mlir/include)
# include_directories(${LLVM_DIR}/tools/clang/include)

# Ensure correct paths
# target_include_directories(kairo PRIVATE ${LLVM_SRC_DIR}/clang/include)
# target_include_directories(kairo PRIVATE ${LLVM_SRC_DIR}/llvm/include)
# target_include_directories(kairo PRIVATE ${LLVM_SRC_DIR}/mlir/include)
# target_include_directories(kairo PRIVATE ${LLVM_DIR}/tools/clang/include)

# Link necessary Clang libraries explicitly
# target_link_libraries(kairo PRIVATE
#     clang-cpp
#     clang
#     clangAST
#     clangASTMatchers
#     clangBasic
#     clangCodeGen
#     clangFrontend
#     clangFrontendTool
#     clangLex
#     clangParse
#     clangSema
#     clangEdit
#     clangDriver
#     clangTooling
#     clangToolingCore
#     clangToolingInclusions
#     clangFormat
#     clangRewrite
#     clangRewriteFrontend
#     clangAnalysis
#     clangARCMigrate
#     clangCrossTU
#     clangIndex
#     clangSerialization
#     clangStaticAnalyzerCore
#     clangStaticAnalyzerFrontend
#     clangStaticAnalyzerCheckers
# )
