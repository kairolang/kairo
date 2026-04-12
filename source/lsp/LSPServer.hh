// LSPServer.hh
#pragma once

#include <atomic>
#include <nlohmann/json.hpp>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>
#include <mutex>
#include <condition_variable>
#include <thread>

#include "controller/include/tooling/tooling.hh"

#ifndef _WIN32
#include <sys/types.h>
#endif

namespace kairo::lsp {

using json = nlohmann::json;

// ─────────────────────────────────────────────────────────────────────────────
// ClangdProxy
// ─────────────────────────────────────────────────────────────────────────────

class ClangdProxy {
  public:
    ClangdProxy() = default;
    ~ClangdProxy() { stop(); }

    bool start(const std::string &clangd_path          = "clangd",
               const std::string &compile_commands_dir = ".");
    void stop();
    bool is_running() const { return _running; }

    void send_notification(const std::string &method, const json &params);
    json send_request(const std::string &method, const json &params);
    void initialize(const std::string &root_uri);
    void set_compile_flags(const std::string              &file_uri,
                           const std::string              &working_dir,
                           const std::vector<std::string> &cmd);

    // read one message, blocking; nullopt on EOF/error
    std::optional<json> read_message();

    // read with deadline; nullopt on timeout or error
    std::optional<json> read_message_timeout(int timeout_ms);

    // drain messages queued while waiting for a prior send_request response
    std::vector<json> drain_pending();

  private:
    int  _next_id     = 1;
    bool _running     = false;
    bool _initialized = false;

#ifdef _WIN32
    HANDLE _process  = INVALID_HANDLE_VALUE;
    HANDLE _stdin_w  = INVALID_HANDLE_VALUE;
    HANDLE _stdout_r = INVALID_HANDLE_VALUE;
#else
    pid_t _pid = -1;
    int   _in  = -1;
    int   _out = -1;
#endif

    std::vector<json> _pending;

    void                write_message(const json &msg);
    std::optional<json> read_one();
    std::optional<json> read_one_timeout(int timeout_ms);
};

// ─────────────────────────────────────────────────────────────────────────────
// LSPServer
// ─────────────────────────────────────────────────────────────────────────────

class LSPServer {
  public:
    void run();

  private:
    // ── clangd state ──────────────────────────────────────────────────────────
    ClangdProxy clangd;
    std::string _root_uri;
    std::string _last_cxx_uri;
    std::string _cache_dir;
    int         _doc_version = 0;
    bool        _shutdown    = false;

    // last successful compile result
    CXXCompileAction         _last_action;
    std::string              _last_kro_file;  // absolute path
    std::vector<std::string> _last_kairo_args;

    std::thread              _debounce_thread;
    std::mutex               _debounce_mutex;
    std::condition_variable  _debounce_cv;
    bool                     _debounce_pending = false;
    bool                     _debounce_stop    = false;
    std::string              _pending_kro_file;
    std::vector<std::string> _pending_kairo_args;
    std::mutex               _compile_mutex;

    void start_debounce_thread();

    // ── wire protocol ─────────────────────────────────────────────────────────
    static std::optional<json> read_lsp_message();
    static void                write_lsp_message(const json &msg);
    static void write_lsp_notification(const std::string &method, const json &params);

    // ── dispatch ──────────────────────────────────────────────────────────────
    std::optional<json> dispatch(const json &msg);

    // ── per-method handlers ───────────────────────────────────────────────────
    json handle_initialize(const json &msg);
    void handle_did_open(const json &msg);
    void handle_did_save(const json &msg);
    void handle_did_change(const json &msg);
    void handle_did_close(const json &msg);
    json handle_hover(const json &msg);
    json handle_definition(const json &msg);
    json handle_completion(const json &msg);
    json handle_references(const json &msg);
    json handle_document_symbols(const json &msg);

    // ── compile pipeline ──────────────────────────────────────────────────────

    // compile .kro → .cxx; populate source map and _last_action
    // returns "" on hard failure (AST errors already emitted as LSP diags)
    std::string compile_and_get_cxx(const std::string              &kro_file,
                                    const std::vector<std::string> &kairo_args,
                                    bool                            force_recompile = false);

    // emit error::ERRORS as a textDocument/publishDiagnostics notification
    void publish_ast_errors(const std::string &kro_file);

    // clear diagnostics for a file (empty diag list)
    void clear_diagnostics(const std::string &kro_file);

    // ── position remapping ────────────────────────────────────────────────────

    // kro (1-based line, col) → cxx (0-based line, character) for LSP params
    std::optional<std::pair<int, int>>
    remap_kro_to_cxx(const std::string &kro_file, int line, int col) const;

    // cxx (1-based line, col from source map) → kro (1-based line, col)
    std::optional<std::pair<std::string, std::pair<int, int>>> remap_cxx_to_kro(int cxir_line,
                                                                                int cxir_col) const;

    // rewrite any LSP Location/Range in a response from cxx coords to kro coords
    json remap_response_locations(const json &result) const;

    // ── clangd forwarding ─────────────────────────────────────────────────────

    // forward an LSP request to clangd (with already-remapped params), return result
    json forward_request(const std::string &method, const json &params);

    // wait for publishDiagnostics for cxx_uri; remap and emit as kro notification
    void collect_and_publish_clangd_diags(const std::string &cxx_uri, const std::string &kro_file);

    // ── helpers ───────────────────────────────────────────────────────────────
    static std::string              uri_to_path(const std::string &uri);
    static std::string              path_to_uri(const std::string &path);
    static std::vector<std::string> clean_compile_cmd(const std::vector<std::string> &cmd);

    static json make_error_response(int id, int code, const std::string &msg);
    static json make_result_response(int id, const json &result);
    // add to private section of LSPServer in the header:
    void sync_file(const std::string &kro_file, const std::vector<std::string> &kairo_args);
    void remap_and_publish_diags(const json &notif, const std::string &kro_file);
    void write_compile_commands(const std::string              &cxx_path,
                                const std::string              &working_dir,
                                const std::vector<std::string> &cmd);

    std::string open_in_clangd(const std::string &cxx_path);
};

}  // namespace kairo::lsp