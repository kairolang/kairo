#ifndef __BACKEND_H__
#define __BACKEND_H__

namespace kairo::backend {
// class CodeGen {
//   public:
//     enum class BackendAction {
//         Backend_Emit_Obj,       ///< emit native object files
//         Backend_Emit_ASM,       ///< emit native assembly files
//         Backend_Emit_LLVM_BC,   ///< emit LLVM bitcode files
//         Backend_Emit_LLVM_ASM,  ///< emit human-readable LLVM assembly
//         Backend_Emit_CXX,       ///< emit semi-readable C++ IR
//         Backend_Emit_C,         ///< emit non-readable C IR (for full C interop)
//         Backend_Emit_FFI,       ///< invoke and generate FFI stubs
//         Backend_Emit_Nothing,   ///< don't emit anything, but go through with the process
//     };

//     enum class OutAction {
//         STDOUT,  ///< output to the stdout
//         FILE,    ///< output to the out_dest
//         STRING,  ///< output as a string
//     };

//     CodeGen() = default;  // default constructor

//     CodeGen(__AST_NODE::Program ast,
//             ASTResolver                resolved_obj,
//             BackendAction              action,
//             string                     out_dest,
//             OutAction                  out_action,
//             Modules                    mods,
//             FIIStandards               ffi_libs,
//             bool                       format_out = false);
// };
}  // namespace kairo::backend

namespace kairo {
class RuntimeInitialize;  ///> initialize the JIT process
class JIT;                ///> invoke the JIT without cli or stdout
class RuntimeCleanup;     ///> close the JIT process (if this is not done you will be left
                          ///  with a ghost process)

class Compile;    ///> invoke a raw compile without cli or stdout
class Toolchain;  ///> invoke the full toolchain with cli args and everything else
}  // namespace kairo

#endif  // __BACKEND_H__