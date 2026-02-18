/// \deprecated THIS FILE IS NOT USED
///
/// \brief since at this stage the kairo compiler is not mature enough to have a tooling API in c++
///        the plan is to rewrite the compiler in kairo itself and have the tooling API built from
///        the ground up

#ifndef __KAIRO_TOOLING_HH__
#define __KAIRO_TOOLING_HH__

/// this cant be done in c++ since it needs really big changes to the internals of the
/// kairo compiler, so this will be done when the compiler is rewritten in kairo itself

#include <filesystem>
#include <memory>
#include <neo-json/include/json.hh>
#include <optional>
#include <string>

#include "controller/include/config/Controller_config.def"
#include "controller/include/shared/file_system.hh"
#include "llvm/Support/MemoryBuffer.h"

/* The Vial file format is as described:
- The file is a binary file
- the file starts with a magic number and a version number
- the file is divided into 3 main sections: the manifest, the data, and the symbol table
- the manifest is a list of key-value pairs that describe the data
- the data contains all the files that are part of the compilation unit
- the symbol table contains all the symbols that are part of the compilation unit
- having the data and the symbol table separate allows for caching and incremental compilation
    @brief having a separate symbol table allows for the following:
           each compile with an import to a vile would be parsed and instead of recompiling the vile
           only the symbol table would be updated and after the first compile of the vile each
           subsequent compile would only need to update the symbol table


| offset | size(B) | field                   | description                                         |
|--------|---------|-------------------------|-----------------------------------------------------|
| 0x00   | 8       | Magic Number            | `0x68656C69782D7669616C` ("kairo-vial" in ASCII)    |
| 0x08   | 2       | Vial Version            | Version of the Vial format                          |
| 0x0A   | 2       | Compiler Version        | Version of the Kairo compiler used to generate      |
| 0x0C   | 4       | Manifest Offset         | Start of the manifest section (metadata in JSON)    |
| 0x10   | 4       | Data Section Offset     | Start of the data (source code and compiled objects)|
| 0x14   | 4       | Symbol Table Offset     | Start of the symbol table (functions, symbols)      |
| 0x18   | 16      | Compilation Timestamp   | Unicode timestamp of the compilation                |
| 0x28   | 4       | Document Section Offset | Start of the document section (user docs)           |
| 0x2C   | 4       | Resource Section Offset | Start of the resources section (images, etc.)       |
| 0x30   | 4       | Signature Offset?       | digital signature for verifying file integrity      |
| 0x34   | 4       | Checksum                | Checksum (e.g., CRC32) of the entire file           |
| 0x38   | 4       | Total File Size         | Total size of the Vial file in bytes                |
| 0x3C   | 4       | Padding                 | padding for 8-byte alignment                        |
*/

__CONTROLLER_TOOL_BEGIN {
    class FileMemoryBuffer {
      public:
        using Path = std::filesystem::path;

        /// enum to represent the type of files handled by the buffer
        ///
        /// \enum FileLevel
        /// \param User user files are files that should be compiled and included
        /// \param Prelude prelude files are included in every compilation
        /// \param Core core files are essential for the compilation unit
        /// \param System system files are symbolized but not compiled
        enum class FileLevel { User, Prelude, Core, System };

        /// enum to represent the type of files handled by the buffer
        ///
        /// \enum FileType
        /// \param Source source code
        /// \param Header header files
        /// \param Object object files
        /// \param Vial vial libraries files
        /// \param Dynamic dynamic libraries
        /// \param AST the fastest way to add to the compile unit
        enum class FileType { Source, Header, Object, Vial, Dynamic, AST };

        /// constructor for creating a file memory buffer. this constructor initializes
        /// a file memory buffer with a source, name, path relative to the current
        /// working directory, and a file type. the buffer is marked as valid if the
        /// source is not empty.
        ///
        /// \param src the source code or content to be held by the buffer.
        /// \param name an optional name for the buffer, defaults to "__/kairo$$internal/__".
        /// \param rel_to the file path relative to which this buffer's path should be resolved.
        ///        defaults to the current working directory.
        /// \param file_type the type of file this buffer represents, defaults to FileLevel::User.
        template <typename T>
        explicit FileMemoryBuffer(T           src,
                                  Path        rel_to     = __CONTROLLER_FS_N::get_cwd(),
                                  std::string name       = "__/kairo$$internal/__",
                                  FileLevel   file_level = FileLevel::User,
                                  FileType    file_type  = FileType::Source)
            : source(std::move(src))
            , name(std::move(name))
            , rel_to(std::move(rel_to))
            , file_level(file_level)
            , file_type(file_type)
            , is_valid(!source.empty()) {}

        /// destructor for the file memory buffer. this destructor is used to clean up
        /// the buffer's resources when it goes out of scope or is no longer needed.
        ~FileMemoryBuffer() = default;

        /// deleted copy constructor to prevent copying of file memory buffers. this
        /// is necessary to ensure that the buffer's contents are not duplicated or
        /// modified unexpectedly.
        ///
        /// \param other the buffer to copy from.
        FileMemoryBuffer(const FileMemoryBuffer &) = delete;

        /// deleted copy assignment operator to force immutability of file memory
        /// buffers. this prevents the buffer's contents from being modified or
        /// replaced after initialization.
        ///
        /// \param other the buffer to copy from.
        FileMemoryBuffer &operator=(const FileMemoryBuffer &) = delete;

        /// move constructor to transfer ownership of a file memory buffer. this
        /// constructor is used to move the contents of a buffer to another buffer,
        /// typically when passing buffers to functions or returning them from
        /// functions.
        ///
        /// \param other the buffer to move from.
        FileMemoryBuffer(FileMemoryBuffer &&) noexcept = default;

        /// move assignment operator to transfer ownership of a file memory buffer.
        /// this operator is used to move the contents of a buffer to another buffer,
        /// typically when passing buffers to functions or returning them from
        /// functions.
        ///
        /// \param other the buffer to move from.
        FileMemoryBuffer &operator=(FileMemoryBuffer &&) noexcept = default;

        /// returns a reference to the source string. this provides direct access to
        /// modify the source string held within the buffer, typically used when the
        /// contents need to be updated or processed.
        [[nodiscard]] std::string &get_source_ref() { return source; }

        /// returns a reference to the buffer name. this provides access to the name
        /// of the buffer which may be used for identification purposes, especially in
        /// contexts where multiple buffers are managed or logged.
        [[nodiscard]] std::string &get_name_ref() { return name; }

        /// returns a reference to the relative path. this path is used to determine
        /// the location of the file in relation to a base directory, commonly used for
        /// resolving physical file paths from logical paths in complex projects.
        [[nodiscard]] Path &get_rel_to_ref() { return rel_to; }

        /// returns the file type as a constant reference. the file type indicates
        /// the role of the file within the system, affecting how it is processed
        /// and utilized within the compilation or execution environment.
        [[nodiscard]] FileLevel get_file_level() const { return file_level; }

        /// checks if the file buffer is valid. a buffer is considered valid if it
        /// contains non-empty source content. this is critical for operations that
        /// should only proceed with valid data.
        [[nodiscard]] bool is_valid_file() const { return is_valid; }

        /// checks if the file buffer is locked. a locked buffer cannot be modified,
        /// ensuring that data remains consistent during operations that require
        /// immutability.
        [[nodiscard]] bool is_locked() const { return locked; }

        /// locks the buffer to prevent modification. this is used to ensure that no
        /// changes are made to the buffer's contents during operations that rely on
        /// data stability, such as multi-threaded access or when performing
        /// read-dependent operations.
        void lock() { locked = true; }

        /// unlocks the buffer to allow modification. this method re-enables the ability
        /// to change the buffer's contents, typically called after a lock is no longer
        /// necessary.
        void unlock() { locked = false; }

        /// returns the size of the buffer. the size is determined by the length of
        /// the source string, representing the amount of data held in the buffer.
        [[nodiscard]] size_t get_buffer_size() const { return source.size(); }

        /// retrieves the buffer content as a string. this method provides a copy of
        /// the buffer's contents, useful for operations that require a non-modifiable
        /// version of the data.
        [[nodiscard]] std::string get_buffer() const { return source; }

        /// set the source of the buffer. this method allows replacing the current
        /// source with a new one, provided the buffer is not locked. this is useful
        /// for dynamic content updates where buffer content needs to be refreshed or
        /// completely changed.
        void set_source(const std::string &src) {
            if (!locked) {
                source   = src;
                is_valid = !source.empty();
            }
        }

      private:
        std::string source;
        std::string name;
        Path        rel_to     = controller::file_system::get_cwd();
        FileLevel   file_level = FileLevel::User;
        FileType    file_type  = FileType::Source;
        bool        is_valid   = false;
        bool        locked     = false;
    };

    class FileIOStram;

    // base classes
    class DiagnosticHandler;
    class InvocationManager;
    class CompilationUnit;
    class FileManager;

    class FrontendProcessor {
      public:
        virtual ~FrontendProcessor() = default;
        virtual void process()       = 0;
    };

    class BackendProcessor {
      public:
        virtual ~BackendProcessor() = default;
        virtual void generate()     = 0;
    };

    // diagnostic handlers
    class PrettyDiagnosticHandler;
    class SimpleDiagnosticHandler;
    class JsonDiagnosticHandler;

    // frontend processors
    class LexicalProcessor : public FrontendProcessor {
      public:
        LexicalProcessor(FileManager &file_manager, const std::string &input_file);
        ~LexicalProcessor() override = default;

        LexicalProcessor(const LexicalProcessor &)                = default;
        LexicalProcessor &operator=(const LexicalProcessor &)     = default;
        LexicalProcessor(LexicalProcessor &&) noexcept            = default;
        LexicalProcessor &operator=(LexicalProcessor &&) noexcept = default;

        void process() override;
    };
    class PreProcessor : public FrontendProcessor {
      public:
        PreProcessor(FileManager &file_manager, const std::string &input_file);
        ~PreProcessor() override = default;

        PreProcessor(const PreProcessor &)                = default;
        PreProcessor &operator=(const PreProcessor &)     = default;
        PreProcessor(PreProcessor &&) noexcept            = default;
        PreProcessor &operator=(PreProcessor &&) noexcept = default;

        void process() override;
    };
    class ASTProcessor : public FrontendProcessor {
      public:
        ASTProcessor(FileManager &file_manager, const std::string &input_file);
        ~ASTProcessor() override = default;

        ASTProcessor(const ASTProcessor &)                = default;
        ASTProcessor &operator=(const ASTProcessor &)     = default;
        ASTProcessor(ASTProcessor &&) noexcept            = default;
        ASTProcessor &operator=(ASTProcessor &&) noexcept = default;

        void process() override;
    };
    class CXXProcessor;  // converts a clang C++ SymbolTable to a Kairo by-directional
                         // SymbolTable
    class SemanticProcessor;
    class VialProcessor;  // generates a Vial file from a Kairo file

    // backend processors
    class CXIRGenerator;
    class LLVMGenerator;
    class ObjectGenerator;

    class ExecutableGenerator : public BackendProcessor {
      public:
        ExecutableGenerator(CXIRGenerator &cxir_gen, const std::string &output_file);
        ~ExecutableGenerator() override = default;

        ExecutableGenerator(const ExecutableGenerator &)                = default;
        ExecutableGenerator &operator=(const ExecutableGenerator &)     = default;
        ExecutableGenerator(ExecutableGenerator &&) noexcept            = default;
        ExecutableGenerator &operator=(ExecutableGenerator &&) noexcept = default;

        void generate() override;
    };

    class CompilationUnit {
      public:
        /**
         * @brief the main constructor for a compilation unit. takes the command-line
         *        arguments and gets the whole thing going.
         * @param argc number of command-line arguments
         * @param argv array of argument strings
         */
        CompilationUnit(int argc, const char **argv);

        explicit CompilationUnit(InvocationManager &invocation);

        template <std::size_t N>
        explicit CompilationUnit(std::array<const char *, N> &argv)
            : CompilationUnit(argv.size(), argv.data()) {}

        template <std::size_t N>
        explicit CompilationUnit(std::array<std::string, N> &argv)
            : CompilationUnit(argv.size(), argv.data()) {}

        ~CompilationUnit();

        CompilationUnit(const CompilationUnit &)            = delete;
        CompilationUnit &operator=(const CompilationUnit &) = delete;

        CompilationUnit(CompilationUnit &&) noexcept            = default;
        CompilationUnit &operator=(CompilationUnit &&) noexcept = default;

        [[nodiscard]] bool initialize();
        [[nodiscard]] bool process();
        void               finalize();

        void set_frontend_processor(std::unique_ptr<FrontendProcessor> frontend);
        void set_backend_processor(std::unique_ptr<BackendProcessor> backend);

        void set_diagnostic_handler(std::unique_ptr<DiagnosticHandler> handler);
        void report_diagnostics() const;

        [[nodiscard]] FileManager       &get_file_manager_ref();
        [[nodiscard]] InvocationManager &get_invocation_manager_ref();

        [[nodiscard]] bool has_errors() const;
        void               clear_errors();
        void               log_status() const;
        void               emit_errors() const;

      private:
        [[nodiscard]] bool validate_inputs() const;
        void               setup_environment();

        void release_resources();

        std::unique_ptr<InvocationManager> invocation;
        std::unique_ptr<DiagnosticHandler> diagnostic_handler;
        std::unique_ptr<FileManager>       file_manager;
        std::unique_ptr<FrontendProcessor> frontend_processor;
        std::unique_ptr<BackendProcessor>  backend_processor;

        bool hasErrors_;
    };
}

#endif  // __KAIRO_TOOLING_HH__