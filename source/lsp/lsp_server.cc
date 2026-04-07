// LSPServer.cc
#include <chrono>
#include <fstream>
#include <iostream>
#include <neo-panic/include/error.hh>
#include <neo-pprint/include/hxpprint.hh>
#include <nlohmann/json.hpp>
#include <sstream>
#include <string>
#include <thread>
#include <utility>

#include "controller/include/cli/cli.hh"
#include "controller/include/shared/file_system.hh"
#include "controller/include/shared/logger.hh"
#include "controller/include/tooling/tooling.hh"
#include "generator/include/CX-IR/CXIR.hh"
#include "lsp/LSPServer.hh"
#include "parser/preprocessor/include/preprocessor.hh"
#include "parser/preprocessor/include/private/utils.hh"

#ifndef _WIN32
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

extern bool NO_LOGS;
extern bool CORE_IMPORTED;  // defined in Controller.cc must reset per request

namespace kairo::lsp {

static std::string DEBUG_PATH =
    __CONTROLLER_FS_N::get_exe().parent_path().parent_path() / "cache" / "kairo_lsp.log";

// ─────────────────────────────────────────────────────────────────────────────
// debug log
// ─────────────────────────────────────────────────────────────────────────────

static void dbg(const std::string &msg) {
    static std::ofstream log(DEBUG_PATH, std::ios::out | std::ios::trunc);
    log << msg << "\n";
    log.flush();
}

// ─────────────────────────────────────────────────────────────────────────────
// ClangdProxy wire
// ─────────────────────────────────────────────────────────────────────────────

bool ClangdProxy::start(const std::string &clangd_path, const std::string &compile_commands_dir) {
#ifdef _WIN32
    SECURITY_ATTRIBUTES sa{};
    sa.nLength              = sizeof(sa);
    sa.bInheritHandle       = TRUE;
    sa.lpSecurityDescriptor = nullptr;

    HANDLE child_stdin_r  = INVALID_HANDLE_VALUE;
    HANDLE child_stdin_w  = INVALID_HANDLE_VALUE;
    HANDLE child_stdout_r = INVALID_HANDLE_VALUE;
    HANDLE child_stdout_w = INVALID_HANDLE_VALUE;

    if (!CreatePipe(&child_stdin_r, &child_stdin_w, &sa, 0))
        return false;
    if (!CreatePipe(&child_stdout_r, &child_stdout_w, &sa, 0)) {
        CloseHandle(child_stdin_r);
        CloseHandle(child_stdin_w);
        return false;
    }

    // our write end of stdin and read end of stdout must NOT be inherited
    SetHandleInformation(child_stdin_w, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(child_stdout_r, HANDLE_FLAG_INHERIT, 0);

    // stderr → log file
    HANDLE stderr_log = CreateFileA("C:\\Temp\\clangd_lsp.log",
                                    GENERIC_WRITE,
                                    FILE_SHARE_READ,
                                    &sa,
                                    CREATE_ALWAYS,
                                    FILE_ATTRIBUTE_NORMAL,
                                    nullptr);
    if (stderr_log == INVALID_HANDLE_VALUE)
        stderr_log = GetStdHandle(STD_ERROR_HANDLE);

    STARTUPINFOA si{};
    si.cb         = sizeof(si);
    si.dwFlags    = STARTF_USESTDHANDLES;
    si.hStdInput  = child_stdin_r;
    si.hStdOutput = child_stdout_w;
    si.hStdError  = stderr_log;

    std::string cmd = clangd_path +
                      " --log=error"
                      " --offset-encoding=utf-16"
                      " --compile-commands-dir=" +
                      compile_commands_dir;

    PROCESS_INFORMATION pi{};
    BOOL ok = CreateProcessA(nullptr,
                             cmd.data(),  // must be mutable — CreateProcessA may modify it
                             nullptr,
                             nullptr,
                             TRUE,  // inherit handles
                             0,
                             nullptr,
                             nullptr,
                             &si,
                             &pi);

    // child-side handles are no longer needed in parent
    CloseHandle(child_stdin_r);
    CloseHandle(child_stdout_w);
    if (stderr_log != GetStdHandle(STD_ERROR_HANDLE))
        CloseHandle(stderr_log);

    if (!ok) {
        CloseHandle(child_stdin_w);
        CloseHandle(child_stdout_r);
        return false;
    }

    CloseHandle(pi.hThread);  // don't need the thread handle

    _process  = pi.hProcess;
    _stdin_w  = child_stdin_w;
    _stdout_r = child_stdout_r;
    _running  = true;
    return true;
#else
    int to_child[2], from_child[2];
    if (pipe(to_child) < 0 || pipe(from_child) < 0)
        return false;

    _pid = fork();
    if (_pid < 0)
        return false;

    if (_pid == 0) {
        dup2(to_child[0], STDIN_FILENO);
        dup2(from_child[1], STDOUT_FILENO);

        int fd = open("/tmp/clangd_lsp.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0)
            dup2(fd, STDERR_FILENO);

        close(to_child[0]);
        close(to_child[1]);
        close(from_child[0]);
        close(from_child[1]);

        execlp(clangd_path.c_str(),
               clangd_path.c_str(),
               "--log=error",
               "--offset-encoding=utf-16",
               ("--compile-commands-dir=" + compile_commands_dir).c_str(),
               nullptr);
        _exit(1);
    }

    close(to_child[0]);
    close(from_child[1]);
    _in      = to_child[1];
    _out     = from_child[0];
    _running = true;
    return true;
#endif
}

void ClangdProxy::stop() {
    if (!_running)
        return;
#ifdef _WIN32
    if (_stdin_w != INVALID_HANDLE_VALUE) {
        CloseHandle(_stdin_w);
        _stdin_w = INVALID_HANDLE_VALUE;
    }
    if (_stdout_r != INVALID_HANDLE_VALUE) {
        CloseHandle(_stdout_r);
        _stdout_r = INVALID_HANDLE_VALUE;
    }
    if (_process != INVALID_HANDLE_VALUE) {
        TerminateProcess(_process, 0);
        WaitForSingleObject(_process, 5000);
        CloseHandle(_process);
        _process = INVALID_HANDLE_VALUE;
    }
#else
    if (_in >= 0) {
        close(_in);
        _in = -1;
    }
    if (_out >= 0) {
        close(_out);
        _out = -1;
    }
    if (_pid > 0) {
        kill(_pid, SIGTERM);
        waitpid(_pid, nullptr, 0);
        _pid = -1;
    }
#endif
    _running     = false;
    _initialized = false;
}

void ClangdProxy::write_message(const json &msg) {
    std::string body  = msg.dump();
    std::string frame = "Content-Length: " + std::to_string(body.size()) + "\r\n\r\n" + body;
    ::write(_in, frame.data(), frame.size());
    dbg("clangd <<< " + body);
}

std::optional<json> ClangdProxy::read_one() {
    // read headers until \r\n\r\n
    std::string headers;
    char        c;
    while (true) {
        ssize_t n = ::read(_out, &c, 1);
        if (n <= 0)
            return std::nullopt;
        headers += c;
        if (headers.size() >= 4 && headers.substr(headers.size() - 4) == "\r\n\r\n")
            break;
    }

    size_t content_length = 0;
    auto   pos            = headers.find("Content-Length: ");
    if (pos != std::string::npos)
        content_length = std::stoul(headers.substr(pos + 16));
    if (content_length == 0)
        return std::nullopt;

    std::string body(content_length, '\0');
    size_t      total = 0;
    while (total < content_length) {
        ssize_t n = ::read(_out, body.data() + total, content_length - total);
        if (n <= 0)
            return std::nullopt;
        total += static_cast<size_t>(n);
    }

    dbg("clangd >>> " + body);

    try {
        return json::parse(body);
    } catch (...) { return std::nullopt; }
}

std::optional<json> ClangdProxy::read_one_timeout(int timeout_ms) {
#ifndef _WIN32
    struct pollfd pfd{_out, POLLIN, 0};
    int           rc = poll(&pfd, 1, timeout_ms);
    if (rc <= 0)
        return std::nullopt;
    return read_one();
#else
    return std::nullopt;
#endif
}

std::optional<json> ClangdProxy::read_message() { return read_one(); }
std::optional<json> ClangdProxy::read_message_timeout(int timeout_ms) {
    return read_one_timeout(timeout_ms);
}

std::vector<json> ClangdProxy::drain_pending() {
    auto out = std::move(_pending);
    _pending.clear();
    return out;
}

void ClangdProxy::send_notification(const std::string &method, const json &params) {
    write_message({{"jsonrpc", "2.0"}, {"method", method}, {"params", params}});
}

json ClangdProxy::send_request(const std::string &method, const json &params) {
    int id = _next_id++;
    write_message({{"jsonrpc", "2.0"}, {"id", id}, {"method", method}, {"params", params}});

    while (true) {
        auto msg = read_one();
        if (!msg)
            return {};
        if (msg->contains("id") && (*msg)["id"] == id)
            return *msg;
        _pending.push_back(*msg);
    }
}

void ClangdProxy::initialize(const std::string &root_uri) {
    if (_initialized)
        return;

    send_request("initialize",
                 {{"processId", static_cast<int>(getpid())},
                  {"rootUri", root_uri},
                  {"capabilities",
                   {{"textDocument",
                     {{"publishDiagnostics", {{"relatedInformation", true}}},
                      {"hover", {{"contentFormat", {"markdown", "plaintext"}}}},
                      {"definition", json::object()},
                      {"completion", {{"completionItem", {{"snippetSupport", false}}}}},
                      {"references", json::object()}}},
                    {"workspace", {{"configuration", true}}}}},
                  {"initializationOptions", {{"clangdFileStatus", false}}}});

    send_notification("initialized", json::object());
    _initialized = true;
    dbg("clangd initialized");
}

void ClangdProxy::set_compile_flags(const std::string              &file_uri,
                                    const std::string              &working_dir,
                                    const std::vector<std::string> &cmd) {
    send_notification(
        "workspace/didChangeConfiguration",
        {{"settings",
          {{"compilationDatabaseChanges",
            {{file_uri, {{"workingDirectory", working_dir}, {"compilationCommand", cmd}}}}}}}});
}

// ─────────────────────────────────────────────────────────────────────────────
// LSPServer wire protocol
// ─────────────────────────────────────────────────────────────────────────────

std::optional<json> LSPServer::read_lsp_message() {
    // read headers
    std::string headers;
    char        c;
    while (true) {
        if (!std::cin.get(c))
            return std::nullopt;
        headers += c;
        if (headers.size() >= 4 && headers.substr(headers.size() - 4) == "\r\n\r\n")
            break;
    }

    size_t content_length = 0;
    auto   pos            = headers.find("Content-Length: ");
    if (pos != std::string::npos)
        content_length = std::stoul(headers.substr(pos + 16));
    if (content_length == 0)
        return std::nullopt;

    std::string body(content_length, '\0');
    if (!std::cin.read(body.data(), static_cast<std::streamsize>(content_length)))
        return std::nullopt;

    dbg("client >>> " + body);

    try {
        return json::parse(body);
    } catch (...) { return std::nullopt; }
}

void LSPServer::write_lsp_message(const json &msg) {
    std::string body  = msg.dump();
    std::string frame = "Content-Length: " + std::to_string(body.size()) + "\r\n\r\n" + body;
    std::cout << frame;
    std::cout.flush();
    dbg("client <<< " + body);
}

void LSPServer::write_lsp_notification(const std::string &method, const json &params) {
    write_lsp_message({{"jsonrpc", "2.0"}, {"method", method}, {"params", params}});
}

json LSPServer::make_error_response(int id, int code, const std::string &msg) {
    return {{"jsonrpc", "2.0"}, {"id", id}, {"error", {{"code", code}, {"message", msg}}}};
}

json LSPServer::make_result_response(int id, const json &result) {
    return {{"jsonrpc", "2.0"}, {"id", id}, {"result", result}};
}

// ─────────────────────────────────────────────────────────────────────────────
// helpers
// ─────────────────────────────────────────────────────────────────────────────

std::string LSPServer::uri_to_path(const std::string &uri) {
    if (uri.size() > 7 && uri.substr(0, 7) == "file://")
        return uri.substr(7);
    return uri;
}

std::string LSPServer::path_to_uri(const std::string &path) {
    if (path.substr(0, 7) == "file://")
        return path;
    return "file://" + path;
}

std::vector<std::string> LSPServer::clean_compile_cmd(const std::vector<std::string> &cmd) {
    std::vector<std::string> out;
    for (auto s : cmd) {
        // trim whitespace
        auto start = s.find_first_not_of(" \t\r\n");
        if (start == std::string::npos)
            continue;
        auto end = s.find_last_not_of(" \t\r\n");
        s        = s.substr(start, end - start + 1);
        if (!s.empty())
            out.push_back(s);
    }
    return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// position remapping
// ─────────────────────────────────────────────────────────────────────────────

std::optional<std::pair<int, int>>
LSPServer::remap_kro_to_cxx(const std::string &kro_file, int line, int col) const {
    // line/col are 1-based from LSP (LSP sends 0-based, callers must convert before calling)
    auto result = generator::CXIR::CXIR::source_map.lookup_kairo(kro_file, line, col);
    if (!result)
        return std::nullopt;
    // return 0-based for LSP
    return std::make_pair((int)result->first - 1, (int)result->second + 2);
}

std::optional<std::pair<std::string, std::pair<int, int>>>
LSPServer::remap_cxx_to_kro(int cxir_line, int cxir_col) const {
    auto result = generator::CXIR::CXIR::source_map.lookup_cxir_adjusted(cxir_line, cxir_col);
    if (!result)
        return std::nullopt;
    return std::make_pair(result->file,
                          std::make_pair((int)result->kairo_line, (int)result->kairo_col));
}

// walk a JSON value and rewrite any LSP Location/Range objects
json LSPServer::remap_response_locations(const json &val) const {
    if (val.is_null())
        return val;

    if (val.is_object()) {
        if (val.contains("uri") && val.contains("range")) {
            json  out   = val;
            auto &range = val["range"];
            if (range.contains("start")) {
                int cxir_line = (int)range["start"]["line"] + 1;
                int cxir_col  = (int)range["start"]["character"] + 2;

                dbg("remap_response_locations: start cxir=(" + std::to_string(cxir_line) + "," +
                    std::to_string(cxir_col) + ") uri=" + val.value("uri", ""));

                // we only remamp if the file given back to us is the generated .cxx, otherwise we
                // might accidentally remap a location from a header or something and give back an
                // invalid kro location it needs to contain "kairoCXIR_" and end with ".cxx" to be
                // considered a remappable generated file
                std::string uri_path = uri_to_path(val.value("uri", ""));
                // also if the uri is like file:///std:c%2B%2Blatest its likely the file we are in
                if (uri_path.find("std:c%2B%2Blatest") == std::string::npos) {
                    if (uri_path.find("kairoCXIR_") == std::string::npos ||
                        uri_path.rfind(".cxx") != uri_path.size() - 4) {
                        dbg("  skipping remap since uri doesn't look like a generated .cxx file" +
                            uri_path);
                        return val;
                    }
                }

                auto remapped = remap_cxx_to_kro(cxir_line, cxir_col);
                if (remapped) {
                    int kline = remapped->second.first - 1;
                    int kcol  = remapped->second.second - 1;

                    dbg("  start remapped -> kro=" + remapped->first + ":(" +
                        std::to_string(kline) + "," + std::to_string(kcol) + ")");

                    out["uri"]            = path_to_uri(remapped->first);
                    out["range"]["start"] = {{"line", kline}, {"character", kcol}};

                    if (range.contains("end")) {
                        int el = (int)range["end"]["line"] + 1;
                        int ec = (int)range["end"]["character"] + 1;

                        dbg("  end cxir=(" + std::to_string(el) + "," + std::to_string(ec) + ")");

                        auto re = remap_cxx_to_kro(el, ec);
                        if (re) {
                            int ekline = re->second.first - 1;
                            int ekcol  = re->second.second - 1;
                            dbg("  end remapped -> kro=(" + std::to_string(ekline) + "," +
                                std::to_string(ekcol) + ")");
                            out["range"]["end"] = {{"line", ekline}, {"character", ekcol}};
                        } else {
                            int start_cxir_line = (int)range["start"]["line"] + 1;
                            int start_cxir_col  = (int)range["start"]["character"] + 1;
                            int width = (el == start_cxir_line) ? (ec - start_cxir_col) : 0;
                            dbg("  end no map, using width=" + std::to_string(width) + " -> kro=(" +
                                std::to_string(kline) + "," + std::to_string(kcol + width) + ")");
                            out["range"]["end"] = {{"line", kline}, {"character", kcol + width}};
                        }
                    }
                } else {
                    dbg("  start no map for cxir=(" + std::to_string(cxir_line) + "," +
                        std::to_string(cxir_col) + ")");
                }
            }
            return out;
        }

        // recurse into all object fields
        json out = json::object();
        for (auto &[k, v] : val.items())
            out[k] = remap_response_locations(v);
        return out;
    }

    if (val.is_array()) {
        json out = json::array();
        for (auto &v : val)
            out.push_back(remap_response_locations(v));
        return out;
    }

    return val;
}

// ─────────────────────────────────────────────────────────────────────────────
// compile pipeline
// ─────────────────────────────────────────────────────────────────────────────

std::string LSPServer::compile_and_get_cxx(const std::string              &kro_file,
                                           const std::vector<std::string> &kairo_args,
                                           bool                            force_recompile) {
    // compile into temporaries first don't nuke state until we succeed
    chdir("/Volumes/Foundry/helix/kairo");

    error::HAS_ERRORED = false;
    error::ERRORS.clear();
    COMPILE_ACTIONS.clear();
    DEPENDENCIES.clear();
    IMPORT_CACHE_MODULE.clear();
    IMPORT_CACHE_HEADER.clear();
    CORE_IMPORTED = false;

    generator::CXIR::CXIR::source_map.reset();

    std::filesystem::path root = std::filesystem::path(uri_to_path(_root_uri));

    std::vector<std::string> argv_storage;
    argv_storage.emplace_back("kairo");
    argv_storage.push_back(kro_file);

    for (auto &a : kairo_args) {
        if (a.size() > 2 && a.substr(0, 2) == "-I") {
            std::filesystem::path inc = std::filesystem::path(a.substr(2));
            if (inc.is_relative()) {
                inc = (root / inc).lexically_normal();
            }
            argv_storage.push_back("-I" + inc.generic_string());
            continue;
        }
        argv_storage.push_back(a);
    }

    std::vector<char *> argv;
    std::string         args_str;
    for (auto &s : argv_storage) {
        argv.push_back(s.data());
        args_str += s + " ";
    }

    dbg("compile_and_get_cxx: kro_file=" + kro_file + " kairo_args=" + args_str +
        " force_recompile=" + (force_recompile ? "true" : "false"));

    char cwd_buf[4096];
    getcwd(cwd_buf, sizeof(cwd_buf));
    dbg("CWD before compile: " + std::string(cwd_buf));
    dbg("chdir result: " + std::to_string(chdir("/Volumes/Foundry/helix/kairo")));
    getcwd(cwd_buf, sizeof(cwd_buf));
    dbg("CWD after chdir: " + std::string(cwd_buf));
    __CONTROLLER_CLI_N::CLIArgs parsed_args(
        static_cast<int>(argv.size()), argv.data(), "kairo-lsp");

    if (parsed_args.file.empty())
        return {};

    dbg("import_dirs after process_paths:");
    for (auto &d : parsed_args.include_dirs)
        dbg("  " + d);

    CompilationUnit unit;
    auto [action, result] = unit.build_unit(parsed_args);

    if (result != 0 || action.cc_source.empty()) {
        return {};  // caller will call publish_ast_errors
    }

    // finalize in case generate_CXIR didn't drain all locs
    // generator::CXIR::CXIR::source_map.finalize();

    dbg("source map after finalize: full_dict size=" +
        std::to_string(generator::CXIR::CXIR::source_map.full_dict.size()));

    for (auto &[k, v] : generator::CXIR::CXIR::source_map.full_dict) {
        dbg("  key=" + k + " entries=" + std::to_string(v.size()));
        // dump first 3 and last 3 entries to verify range
        size_t n = v.size();
        for (size_t i = 0; i < std::min(n, (size_t)3); ++i)
            dbg("    [" + std::to_string(i) + "] " + v[i]);
        if (n > 6)
            dbg("    ...");
        for (size_t i = (n > 3 ? n - 3 : 3); i < n; ++i)
            dbg("    [" + std::to_string(i) + "] " + v[i]);
    }
    // for (auto &[k, v] : generator::CXIR::CXIR::source_map.full_dict)
    //     dbg("  key=" + k + " entries=" + std::to_string(v.size()));

    // dry run populates full_cxx_args without invoking the compiler
    CXXCompileAction action_for_dry = action;
    CXIRCompiler     dry_compiler;
    dry_compiler.compile_CXIR(std::move(action_for_dry), /*dry_run=*/true);

    _last_action               = action;
    _last_action.full_cxx_args = action_for_dry.full_cxx_args;
    _last_kro_file             = kro_file;
    _last_kairo_args           = kairo_args;

    dbg("compile_and_get_cxx: cxx=" + action.cc_source.generic_string() +
        " cmd_entries=" + std::to_string(_last_action.full_cxx_args.size()));

    return action.cc_source.generic_string();
}

void LSPServer::publish_ast_errors(const std::string &kro_file) {
    json diagnostics = json::array();

    for (auto &err : error::ERRORS) {
        if (err.level == "none")
            continue;

        // only emit errors for this file
        if (!err.file.empty() && err.file != kro_file)
            continue;

        int sev = 1;  // error
        if (err.level == "warn")
            sev = 2;
        if (err.level == "note")
            sev = 3;
        if (err.level == "info")
            sev = 4;
        if (err.level == "fatal")
            sev = 1;

        int line   = (err.line > 0) ? (int)err.line - 1 : 0;
        int col    = (err.col > 0) ? (int)err.col
                                   : 0;  // no -1 for col because LSP expects 1-based cols from us
        int endcol = col + (int)err.offset;  // offset is the token length

        json diag = {{"range",
                      {{"start", {{"line", line}, {"character", col}}},
                       {"end", {{"line", line}, {"character", endcol}}}}},
                     {"severity", sev},
                     {"source", "kairo"},
                     {"message", err.msg}};

        // quick_fix → LSP codeAction data
        if (!err.quick_fix.empty()) {
            json fixes = json::array();
            for (auto &[fix_text, pos] : err.quick_fix) {
                fixes.push_back({{"fix", fix_text}, {"pos", pos}});
            }
            diag["data"] = {{"quick_fixes", fixes}};
        } else if (!err.fix.empty()) {
            diag["data"] = {{"fix", err.fix}};
        }

        // attach related info if we have a display hint
        if (!err.display.empty()) {
            diag["relatedInformation"] =
                json::array({{{"location",
                               {{"uri", path_to_uri(err.file.empty() ? kro_file : err.file)},
                                {"range",
                                 {{"start", {{"line", line}, {"character", col}}},
                                  {"end", {{"line", line}, {"character", endcol}}}}}}},
                              {"message", err.display}}});
        }

        diagnostics.push_back(diag);
    }

    write_lsp_notification("textDocument/publishDiagnostics",
                           {{"uri", path_to_uri(kro_file)}, {"diagnostics", diagnostics}});

    dbg("published " + std::to_string(diagnostics.size()) + " AST errors for " + kro_file);
}

void LSPServer::clear_diagnostics(const std::string &kro_file) {
    write_lsp_notification("textDocument/publishDiagnostics",
                           {{"uri", path_to_uri(kro_file)}, {"diagnostics", json::array()}});
}

// ─────────────────────────────────────────────────────────────────────────────
// clangd forwarding
// ─────────────────────────────────────────────────────────────────────────────

json LSPServer::forward_request(const std::string &method, const json &params) {
    return clangd.send_request(method, params);
}

void LSPServer::collect_and_publish_clangd_diags(const std::string &cxx_uri,
                                                 const std::string &kro_file) {
    // drain pending first
    for (auto &n : clangd.drain_pending()) {
        std::string m   = n.value("method", "");
        std::string uri = n.contains("params") ? n["params"].value("uri", "") : "";
        if (m == "textDocument/publishDiagnostics" && uri == cxx_uri) {
            // don't accept empty clangd hasn't analyzed yet
            if (!n["params"]["diagnostics"].empty()) {
                remap_and_publish_diags(n, kro_file);
                return;
            }
        }
    }

    json best;  // best non-empty diag set we've seen
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);

    while (std::chrono::steady_clock::now() < deadline) {
        int  remaining_ms = (int)std::chrono::duration_cast<std::chrono::milliseconds>(
                                deadline - std::chrono::steady_clock::now())
                                .count();
        auto msg          = clangd.read_message_timeout(remaining_ms);
        if (!msg)
            break;

        std::string m   = msg->value("method", "");
        std::string uri = msg->contains("params") ? (*msg)["params"].value("uri", "") : "";
        dbg("poll: method=" + m + " uri=" + uri);

        if (m == "textDocument/publishDiagnostics" && uri == cxx_uri) {
            if (!(*msg)["params"]["diagnostics"].empty()) {
                // got real diags publish immediately and return
                remap_and_publish_diags(*msg, kro_file);
                return;
            }
            // empty clangd is still warming up, keep waiting
            dbg("poll: empty diags, waiting for real ones");
            continue;
        }
    }

    // timed out if we never got anything, publish empty to clear stale errors
    dbg("timed out waiting for non-empty diags");
    clear_diagnostics(kro_file);
}

void LSPServer::remap_and_publish_diags(const json &notif, const std::string &kro_file) {
    json diagnostics = json::array();

    if (!notif.contains("params") || !notif["params"].contains("diagnostics")) {
        write_lsp_notification("textDocument/publishDiagnostics",
                               {{"uri", path_to_uri(kro_file)}, {"diagnostics", diagnostics}});
        return;
    }

    for (auto &d : notif["params"]["diagnostics"]) {
        auto &cxir_start = d["range"]["start"];
        auto &cxir_end   = d["range"]["end"];

        int cxir_line = (int)cxir_start["line"] + 1;
        int cxir_col  = (int)cxir_start["character"] + 1;

        auto mapped = remap_cxx_to_kro(cxir_line, cxir_col);
        if (!mapped) {
            dbg("  diag drop (no map): cxir=(" + std::to_string(cxir_line) + "," +
                std::to_string(cxir_col) + ") msg=" + d.value("message", ""));
            continue;
        }

        if (mapped->first.find("/core/") != std::string::npos) {
            dbg("  diag drop (core file): " + mapped->first);
            continue;
        }

        int kline = mapped->second.first - 1;
        int kcol  = mapped->second.second;

        int start_line = (int)cxir_start["line"];
        int start_col  = (int)cxir_start["character"];
        int end_line   = (int)cxir_end["line"];
        int end_col    = (int)cxir_end["character"];

        auto remapped_end = remap_cxx_to_kro(end_line + 1, kcol + (end_col - start_col) - 1);
        int  end_kline    = remapped_end ? remapped_end->second.first - 1 : kline;
        int  end_kcol = remapped_end ? remapped_end->second.second : (kcol + (end_col - start_col));

        if (end_line != start_line) {
            auto mapped_end = remap_cxx_to_kro(end_line + 1, end_col + 1);
            if (mapped_end) {
                end_kline = mapped_end->second.first - 1;
                end_kcol  = mapped_end->second.second - 1;
            }
        }

        // demangle message
        std::string msg =
            helix::abi::strip_helix_prefix(helix::abi::demangle_partial(d.value("message", "")));

        json diag = {{"range",
                      {{"start", {{"line", kline}, {"character", kcol}}},
                       {"end", {{"line", end_kline}, {"character", end_kcol}}}}},
                     {"severity", d.value("severity", 1)},
                     {"source", "kairo/clangd"},
                     {"message", msg}};

        if (d.contains("relatedInformation")) {
            json ri = d["relatedInformation"];
            for (auto &item : ri) {
                if (item.contains("message"))
                    item["message"] = helix::abi::strip_helix_prefix(
                        helix::abi::demangle_partial(item["message"].get<std::string>()));
                if (item.contains("location"))
                    item["location"] = remap_response_locations(item["location"]);
            }
            diag["relatedInformation"] = ri;
        }

        diagnostics.push_back(diag);
        dbg("  diag kept: " + mapped->first + ":" + std::to_string(kline + 1) + " cols " +
            std::to_string(kcol) + "-" + std::to_string(end_kcol) + " msg=" + msg);
    }

    write_lsp_notification("textDocument/publishDiagnostics",
                           {{"uri", path_to_uri(kro_file)}, {"diagnostics", diagnostics}});

    dbg("published " + std::to_string(diagnostics.size()) + " clangd diags for " + kro_file);
}

// ─────────────────────────────────────────────────────────────────────────────
// method handlers
// ─────────────────────────────────────────────────────────────────────────────

json LSPServer::handle_initialize(const json &msg) {
    _cache_dir = (__CONTROLLER_FS_N::get_exe().parent_path().parent_path() / "cache" / "cxx")
                     .generic_string();

    std::filesystem::create_directories(_cache_dir);

    int id = msg.value("id", 0);

    if (msg.contains("params") && msg["params"].contains("rootUri"))
        _root_uri = msg["params"]["rootUri"];
    else if (msg.contains("params") && msg["params"].contains("rootPath"))
        _root_uri = path_to_uri(msg["params"].value("rootPath", ""));

    if (!clangd.is_running()) {
        clangd.start("clangd", _cache_dir);
        clangd.initialize(_root_uri.empty() ? "file:///tmp" : _root_uri);
    }

    return make_result_response(
        id,
        {{"capabilities",
          {{"textDocumentSync", {{"openClose", true}, {"change", 1}}},  // 1=full
           {"hoverProvider", true},
           {"definitionProvider", true},
           {"referencesProvider", true},
           {"documentSymbolProvider", true},
           {"completionProvider", {{"triggerCharacters", {".", ":", ">"}}}}}},
         {"serverInfo", {{"name", "kairo-lsp"}, {"version", "0.1"}}}});
}

void LSPServer::write_compile_commands(const std::string              &cxx_path,
                                       const std::string              &working_dir,
                                       const std::vector<std::string> &cmd) {
    std::string cmd_str;
    for (auto &s : cmd) {
        if (!cmd_str.empty())
            cmd_str += " ";
        cmd_str += s;
    }

    json cc = json::array();
    cc.push_back({{"directory", working_dir}, {"file", cxx_path}, {"command", cmd_str}});

    auto          out = std::filesystem::path(cxx_path).parent_path() / "compile_commands.json";
    std::ofstream f(out);
    f << cc.dump(2);

    dbg("wrote compile_commands.json: " + out.generic_string());
}

// shared compile + clangd-open logic used by didOpen and didChange
void LSPServer::sync_file(const std::string &kro_file, const std::vector<std::string> &kairo_args) {
    std::string cxx_path = compile_and_get_cxx(kro_file, kairo_args, true);
    if (cxx_path.empty()) {
        publish_ast_errors(kro_file);
        return;
    }
    clear_diagnostics(kro_file);
    open_in_clangd(cxx_path);
    collect_and_publish_clangd_diags(_last_cxx_uri, kro_file);
}

void LSPServer::handle_did_open(const json &msg) {
    if (!msg.contains("params"))
        return;
    auto &p = msg["params"];

    std::string kro_uri  = p["textDocument"].value("uri", "");
    std::string kro_file = uri_to_path(kro_uri);

    std::vector<std::string> kairo_args;
    if (p.contains("kairoArgs") && p["kairoArgs"].is_array())
        kairo_args = p["kairoArgs"].get<std::vector<std::string>>();

    sync_file(kro_file, kairo_args);
}

void LSPServer::handle_did_save(const json &msg) {
    if (!msg.contains("params"))
        return;
    std::string kro_file = uri_to_path(msg["params"]["textDocument"].value("uri", ""));
    sync_file(kro_file, _last_kairo_args);
}

void LSPServer::handle_did_close(const json &msg) {
    if (!msg.contains("params"))
        return;
    std::string kro_uri  = msg["params"]["textDocument"].value("uri", "");
    std::string kro_file = uri_to_path(kro_uri);

    clear_diagnostics(kro_file);

    if (!_last_cxx_uri.empty()) {
        clangd.send_notification("textDocument/didClose",
                                 {{"textDocument", {{"uri", _last_cxx_uri}}}});
        _last_cxx_uri.clear();
    }
}

json LSPServer::handle_hover(const json &msg) {
    int id = msg.value("id", 0);
    if (!msg.contains("params"))
        return make_result_response(id, nullptr);

    auto       &p        = msg["params"];
    std::string kro_uri  = p["textDocument"].value("uri", "");
    std::string kro_file = uri_to_path(kro_uri);
    int         kro_line = (int)p["position"].value("line", 0) + 1;  // to 1-based
    int         kro_col  = (int)p["position"].value("character", 0) + 1;

    std::vector<std::string> kairo_args;
    if (p.contains("kairoArgs") && p["kairoArgs"].is_array())
        kairo_args = p["kairoArgs"].get<std::vector<std::string>>();

    if (kairo_args.empty())
        kairo_args = _last_kairo_args;

    // recompile if file changed or args changed
    if (kro_file != _last_kro_file || kairo_args != _last_kairo_args) {
        std::string cxx_path = compile_and_get_cxx(kro_file, kairo_args);
        if (cxx_path.empty()) {
            publish_ast_errors(kro_file);
            return make_result_response(id, nullptr);
        }
        open_in_clangd(cxx_path);  // updates _last_cxx_uri, opens in clangd
        // brief wait for clangd to index before sending the request
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }

    auto cxx_pos = remap_kro_to_cxx(kro_file, kro_line, kro_col);
    if (!cxx_pos) {
        dbg("hover: no source map entry for " + kro_file + ":" + std::to_string(kro_line) + ":" +
            std::to_string(kro_col));
        return make_result_response(id, nullptr);
    }

    json clangd_params = {{"textDocument", {{"uri", _last_cxx_uri}}},
                          {"position", {{"line", cxx_pos->first}, {"character", cxx_pos->second}}}};

    auto response = forward_request("textDocument/hover", clangd_params);

    /// we need to demangle the contents in result: contents: value
    if (response.contains("result") && !response["result"].is_null() &&
        response["result"].contains("contents")) {
        auto &contents = response["result"]["contents"];

        auto demangle_str = [](const std::string &s) {
            return helix::abi::strip_helix_prefix(helix::abi::demangle_partial(s));
        };

        if (contents.is_string()) {
            contents = demangle_str(contents.get<std::string>());
        } else if (contents.is_object() && contents.contains("value") &&
                   contents["value"].is_string()) {
            // MarkupContent { kind, value } — this is what clangd actually sends
            contents["value"] = demangle_str(contents["value"].get<std::string>());
        } else if (contents.is_array()) {
            for (auto &item : contents) {
                if (item.is_string()) {
                    item = demangle_str(item.get<std::string>());
                } else if (item.is_object() && item.contains("value") &&
                           item["value"].is_string()) {
                    item["value"] = demangle_str(item["value"].get<std::string>());
                }
            }
        }
    }

    if (!response.contains("result") || response["result"].is_null())
        return make_result_response(id, nullptr);

    // remap range in result if present
    json result = response["result"];
    if (result.contains("range")) {
        auto remapped =
            remap_response_locations(json{{"uri", _last_cxx_uri}, {"range", result["range"]}});
        if (remapped.contains("range"))
            result["range"] = remapped["range"];
    }

    return make_result_response(id, result);
}

json LSPServer::handle_definition(const json &msg) {
    int id = msg.value("id", 0);
    if (!msg.contains("params"))
        return make_result_response(id, nullptr);

    auto       &p        = msg["params"];
    std::string kro_uri  = p["textDocument"].value("uri", "");
    std::string kro_file = uri_to_path(kro_uri);
    int         kro_line = (int)p["position"].value("line", 0) + 1;
    int         kro_col  = (int)p["position"].value("character", 0) + 1;

    std::vector<std::string> kairo_args;
    if (p.contains("kairoArgs") && p["kairoArgs"].is_array())
        kairo_args = p["kairoArgs"].get<std::vector<std::string>>();

    if (kairo_args.empty())
        kairo_args = _last_kairo_args;

    if (kro_file != _last_kro_file || kairo_args != _last_kairo_args) {
        std::string cxx_path = compile_and_get_cxx(kro_file, kairo_args);
        if (cxx_path.empty()) {
            publish_ast_errors(kro_file);
            return make_result_response(id, nullptr);
        }
        open_in_clangd(cxx_path);  // updates _last_cxx_uri, opens in clangd
        // brief wait for clangd to index before sending the request
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }

    auto cxx_pos = remap_kro_to_cxx(kro_file, kro_line, kro_col);
    if (!cxx_pos)
        return make_result_response(id, nullptr);

    json clangd_params = {{"textDocument", {{"uri", _last_cxx_uri}}},
                          {"position", {{"line", cxx_pos->first}, {"character", cxx_pos->second}}}};

    auto response = forward_request("textDocument/definition", clangd_params);
    if (!response.contains("result"))
        return make_result_response(id, nullptr);

    return make_result_response(id, remap_response_locations(response["result"]));
}

json LSPServer::handle_completion(const json &msg) {
    int id = msg.value("id", 0);
    if (!msg.contains("params"))
        return make_result_response(id, nullptr);

    auto       &p        = msg["params"];
    std::string kro_uri  = p["textDocument"].value("uri", "");
    std::string kro_file = uri_to_path(kro_uri);
    int         kro_line = (int)p["position"].value("line", 0) + 1;
    int         kro_col  = (int)p["position"].value("character", 0) + 1;

    std::vector<std::string> kairo_args;
    if (p.contains("kairoArgs") && p["kairoArgs"].is_array())
        kairo_args = p["kairoArgs"].get<std::vector<std::string>>();

    if (kairo_args.empty())
        kairo_args = _last_kairo_args;

    if (kro_file != _last_kro_file || kairo_args != _last_kairo_args) {
        std::string cxx_path = compile_and_get_cxx(kro_file, kairo_args);
        if (cxx_path.empty()) {
            publish_ast_errors(kro_file);
            return make_result_response(id, nullptr);
        }
        open_in_clangd(cxx_path);  // updates _last_cxx_uri, opens in clangd
        // brief wait for clangd to index before sending the request
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }

    auto cxx_pos = remap_kro_to_cxx(kro_file, kro_line, kro_col);
    if (!cxx_pos)
        return make_result_response(id, nullptr);

    json clangd_params = {{"textDocument", {{"uri", _last_cxx_uri}}},
                          {"position", {{"line", cxx_pos->first}, {"character", cxx_pos->second}}}};

    if (p.contains("context"))
        clangd_params["context"] = p["context"];

    auto response = forward_request("textDocument/completion", clangd_params);
    if (!response.contains("result"))
        return make_result_response(id, nullptr);

    // completion items don't have location ranges to remap return as-is
    return make_result_response(id, response["result"]);
}

json LSPServer::handle_references(const json &msg) {
    int id = msg.value("id", 0);
    if (!msg.contains("params"))
        return make_result_response(id, nullptr);

    auto       &p        = msg["params"];
    std::string kro_uri  = p["textDocument"].value("uri", "");
    std::string kro_file = uri_to_path(kro_uri);
    int         kro_line = (int)p["position"].value("line", 0) + 1;
    int         kro_col  = (int)p["position"].value("character", 0) + 1;

    std::vector<std::string> kairo_args;
    if (p.contains("kairoArgs") && p["kairoArgs"].is_array())
        kairo_args = p["kairoArgs"].get<std::vector<std::string>>();

    if (kairo_args.empty())
        kairo_args = _last_kairo_args;

    if (kro_file != _last_kro_file || kairo_args != _last_kairo_args) {
        std::string cxx_path = compile_and_get_cxx(kro_file, kairo_args);
        if (cxx_path.empty()) {
            publish_ast_errors(kro_file);
            return make_result_response(id, nullptr);
        }
        open_in_clangd(cxx_path);  // updates _last_cxx_uri, opens in clangd
        // brief wait for clangd to index before sending the request
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }

    auto cxx_pos = remap_kro_to_cxx(kro_file, kro_line, kro_col);
    if (!cxx_pos)
        return make_result_response(id, nullptr);

    json clangd_params = {{"textDocument", {{"uri", _last_cxx_uri}}},
                          {"position", {{"line", cxx_pos->first}, {"character", cxx_pos->second}}},
                          {"context", p.value("context", json::object())}};

    auto response = forward_request("textDocument/references", clangd_params);
    if (!response.contains("result"))
        return make_result_response(id, nullptr);

    return make_result_response(id, remap_response_locations(response["result"]));
}

json LSPServer::handle_document_symbols(const json &msg) {
    int id = msg.value("id", 0);
    if (!msg.contains("params"))
        return make_result_response(id, json::array());

    json clangd_params = {{"textDocument", {{"uri", _last_cxx_uri}}}};
    auto response      = forward_request("textDocument/documentSymbol", clangd_params);
    if (!response.contains("result"))
        return make_result_response(id, json::array());

    json out = json::array();
    for (auto &sym : response["result"]) {
        if (!sym.contains("location"))
            continue;

        int  cxir_line = (int)sym["location"]["range"]["start"]["line"] + 1;
        int  cxir_col  = (int)sym["location"]["range"]["start"]["character"] + 1;
        auto mapped    = remap_cxx_to_kro(cxir_line, cxir_col);
        if (!mapped)
            continue;

        if (mapped->first.find("/core/") != std::string::npos)
            continue;

        json s = sym;
        s["name"] =
            helix::abi::strip_helix_prefix(helix::abi::demangle_partial(sym.value("name", "")));
        if (s.contains("detail"))
            s["detail"] = helix::abi::strip_helix_prefix(
                helix::abi::demangle_partial(sym["detail"].get<std::string>()));

        int kline                       = mapped->second.first - 1;
        int kcol                        = mapped->second.second - 1;
        s["location"]["uri"]            = path_to_uri(mapped->first);
        s["location"]["range"]["start"] = {{"line", kline}, {"character", kcol}};
        s["location"]["range"]["end"]   = {{"line", kline}, {"character", kcol}};

        out.push_back(s);
    }

    return make_result_response(id, out);
}

// ─────────────────────────────────────────────────────────────────────────────
// dispatch
// ─────────────────────────────────────────────────────────────────────────────

std::optional<json> LSPServer::dispatch(const json &msg) {
    std::string method     = msg.value("method", "");
    bool        is_request = msg.contains("id");

    dbg("dispatch: method=" + method + " is_request=" + std::to_string(is_request));

    // ── lifecycle ─────────────────────────────────────────────────────────────
    if (method == "initialize")
        return handle_initialize(msg);

    if (method == "initialized")
        return std::nullopt;  // notification, no response

    if (method == "shutdown") {
        _shutdown = true;
        return make_result_response(msg.value("id", 0), nullptr);
    }

    if (method == "exit") {
        clangd.stop();
        std::exit(_shutdown ? 0 : 1);
    }

    // ── document sync ─────────────────────────────────────────────────────────
    if (method == "textDocument/didOpen") {
        handle_did_open(msg);
        return std::nullopt;
    }
    if (method == "textDocument/didChange") {
        handle_did_save(msg);
        return std::nullopt;
    }
    if (method == "textDocument/didClose") {
        handle_did_close(msg);
        return std::nullopt;
    }

    // ── language features ─────────────────────────────────────────────────────
    if (method == "textDocument/hover")
        return handle_hover(msg);
    if (method == "textDocument/definition")
        return handle_definition(msg);
    if (method == "textDocument/completion")
        return handle_completion(msg);
    if (method == "textDocument/references")
        return handle_references(msg);
    if (method == "textDocument/documentSymbol")
        return handle_document_symbols(msg);

    // ── cancel / misc ─────────────────────────────────────────────────────────
    if (method == "$/cancelRequest") {
        if (clangd.is_running() && msg.contains("params"))
            clangd.send_notification("$/cancelRequest", msg["params"]);
        return std::nullopt;
    }

    // unknown request return method not found
    if (is_request)
        return make_error_response(msg.value("id", 0), -32601, "method not found: " + method);

    return std::nullopt;
}

// returns new cxx_path, updates _last_cxx_uri, opens file in clangd
// does NOT wait for diagnostics
std::string LSPServer::open_in_clangd(const std::string &cxx_path) {
    std::string cxx_uri     = path_to_uri(cxx_path);
    std::string working_dir = _last_action.working_dir.generic_string();
    auto        compile_cmd = clean_compile_cmd(_last_action.full_cxx_args);
    write_compile_commands(cxx_path, working_dir, compile_cmd);

    clangd.set_compile_flags(cxx_uri, working_dir, compile_cmd);

    if (!_last_cxx_uri.empty() && _last_cxx_uri != cxx_uri)
        clangd.send_notification("textDocument/didClose",
                                 {{"textDocument", {{"uri", _last_cxx_uri}}}});

    if (_last_cxx_uri == cxx_uri) {
        clangd.send_notification("textDocument/didClose", {{"textDocument", {{"uri", cxx_uri}}}});
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    std::ifstream f(cxx_path);
    std::string   content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    clangd.send_notification("textDocument/didOpen",
                             {{"textDocument",
                               {{"uri", cxx_uri},
                                {"languageId", "cpp"},
                                {"version", ++_doc_version},
                                {"text", content}}}});
    _last_cxx_uri = cxx_uri;
    return cxx_uri;
}

// ─────────────────────────────────────────────────────────────────────────────
// main loop
// ─────────────────────────────────────────────────────────────────────────────

void LSPServer::run() {
    NO_LOGS           = true;
    error::SHOW_ERROR = false;

    // we make a new dbg file on each run to avoid interleaving logs from multiple runs which can be
    // confusing DEBUG_PATH is set at the top of this file
    if (!DEBUG_PATH.empty()) {  // only create dbg file if debugging is enabled
        std::ofstream dbg_file(DEBUG_PATH, std::ios::trunc);  // truncate to start fresh
        dbg_file.close();
    }

    while (true) {
        auto msg = read_lsp_message();
        if (!msg)
            break;

        auto response = dispatch(*msg);
        if (response)
            write_lsp_message(*response);
    }

    clangd.stop();
}

}  // namespace kairo::lsp