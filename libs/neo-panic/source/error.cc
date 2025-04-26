//===------------------------------------------------------------------------------------------===//
//
// Part of the Helix Project, under the Attribution 4.0 International license (CC BY 4.0).
// You are allowed to use, modify, redistribute, and create derivative works, even for commercial
// purposes, provided that you give appropriate credit, and indicate if changes were made.
// For more information, please visit: https://creativecommons.org/licenses/by/4.0/
//
// SPDX-License-Identifier: CC-BY-4.0
// Copyright (c) 2024 (CC BY 4.0)
//
//===------------------------------------------------------------------------------------------===//
#include "neo-panic/include/error.hh"

#include <array>
#include <cstddef>
#include <iomanip>
#include <numeric>
#include <optional>
#include <ostream>
#include <sstream>
#include <stdexcept>
#include <tuple>
#include <vector>

#include "controller/include/Controller.hh"
#include "neo-panic/enums/error_codes.def"
#include "neo-pprint/include/ansi_colors.hh"
#include "neo-pprint/include/hxpprint.hh"
#include "token/include/Token.hh"

namespace std {
static inline void lstrip(std::string &str) {
    str.erase(str.begin(), std::find_if(str.begin(), str.end(), [](unsigned char chr) {
                  return std::isspace(chr) == 0;
              }));
}

// Trim from the end (in place)
static inline void rstrip(std::string &str) {
    str.erase(std::find_if(str.rbegin(),
                           str.rend(),
                           [](unsigned char chr) { return std::isspace(chr) == 0; })
                  .base(),
              str.end());
}

// Trim from both ends (in place)
static inline void strip(std::string &str) {
    lstrip(str);
    rstrip(str);
}

template <typename T>
class Reverse {
  public:
    explicit Reverse(T &container)
        : container(container) {}

    auto begin() const { return container.rbegin(); }
    auto end() const { return container.rend(); }

  private:
    T &container;
};

void string_insert(string &str, const string &insert, i64 pos, size_t str_size = 0) {
    str_size = str.size();

    if (pos < 0) {
        pos = static_cast<i64>(str_size) + (pos + 1);
    }

    if (pos < 0) {
        pos = 0;
    }

    if (pos > static_cast<i64>(str_size)) {
        return;  // out of bounds
    }

    for (size_t i = 0; i < insert.size(); i++) {
        str.insert((str.begin() + static_cast<i64>(pos + i)), insert[i]);
    }
}
}  // namespace std

/**
 @namespace error
 * @brief Contains classes and functions related to error handling and reporting.
 */
namespace error {
// (discard, (line_no line, is_pof))
using line_type = std::pair<bool, std::tuple<string, string, bool>>;
using lines_vec = std::vector<line_type>;

// Check if a string is empty or contains only whitespace
bool is_empty_or_whitespace(const std::string &str) {
    std::string trimmed = str;
    std::strip(trimmed);
    return trimmed.empty();
}

string err_color   = string(colors::effects::bold) + string(colors::fg8::red);
string green_color = string(colors::effects::bold) + string(colors::fg8::green);
string ret_color   = string(colors::fg8::white);

string error_color(const string &str) { return err_color + str + ret_color; };

string fix_color(const string &str) { return green_color + str + ret_color; };

string bold_white(const string &str) {
    return string(colors::effects::bold) + string(colors::fg8::white) + str + string(colors::reset);
}

string green(const string &str) {
    return string(colors::fg8::green) + str + string(colors::reset);
};

string yellow(const string &str) {
    return string(colors::fg16::yellow) + str + string(colors::reset);
};

string format_loc_info(const string &file_name, u64 line, u64 col) {
    return green(file_name) + ":" + yellow(std::to_string(line)) + ":" +
           yellow(std::to_string(col));
};

lines_vec get_surrounding_lines(const string &file_name, u64 line) {
    // if odd number, get even amount of lines behind and after
    // if even number, get -1 lines before and same amount of lines after

    // calculate lines to get before

    u64 lines_before = (LINES_TO_SHOW % 2 == 0) ? (LINES_TO_SHOW / 2) - 1 : (LINES_TO_SHOW / 2);
    lines_vec lines;  // {bool : (string, string, bool)}

    u64 start_line = (line <= lines_before) ? 1 : (line - lines_before);

    for (u64 i = start_line; i < start_line + LINES_TO_SHOW; ++i) {
        auto line_content = __CONTROLLER_FS_N::get_line(file_name, i);
        if (line_content.has_value()) {
            lines.emplace_back(false,
                               std::make_tuple(std::to_string(i), line_content.value(), i == line));
        } else {
            break;
        }
    }

    // remove blank lines from either side

    for (auto &line : lines) {
        if (std::get<2>(line.second)) {
            break;  // we have marked discard for the part before the error line
        }

        if (is_empty_or_whitespace(std::get<1>(line.second))) {
            line.first = true;  // set discard to true
        } else {
            break;
        }
    }

    for (auto &line : std::Reverse(lines)) {
        if (std::get<2>(line.second)) {
            break;  // we have marked discard for the part after the error line
        }

        if (is_empty_or_whitespace(std::get<1>(line.second))) {
            line.first = true;  // set discard to true
        } else {
            break;
        }
    }

    // remove all the elements marked for discard from 'lines' of type
    // std::vector<std::pair<bool, std::tuple<string, string, bool>>>
    // aka {discard : (line_no, line, is_err_line)}

    lines.erase(std::remove_if(lines.begin(),
                               lines.end(),
                               [](const auto &line) {
                                   return line.first;  // discard is true
                               }),
                lines.end());

    return lines;
};

/*
theres a error for some odd reason (noticeable when there more then 2 fixes)
*/
string color_and_mark(line_type                          &line_typ,
                      u64                                 col,
                      u64                                 len,
                      std::vector<std::pair<string, u32>> quick_fix = {},
                      bool                                mark_pof  = true) {
    string line_no               = std::get<0>(line_typ.second);
    string line                  = std::get<1>(line_typ.second) + " ";
    bool   is_pof                = std::get<2>(line_typ.second);
    bool   did_add_inside_marked = false;

    string marking(line.size(), ' ');

    auto resize_line_if_needed = [](string &line, u64 size) {
        if (line.size() < size) {
            line.resize(size + 1, ' ');
        }
    };

    auto insert_mark = [&](u64 position, string fix, bool inside_marked = false) {
        resize_line_if_needed(line, position);
        std::string_insert(line, fix, position);

        string mark_color = inside_marked ? err_color : "";
        std::string_insert(
            marking,
            fix_color(string(
                fix.length() - (err_color.length() + ret_color.length() + (inside_marked ? 1 : 0)),
                '+')) +
                mark_color,
            position);

        marking += " ";
    };

    std::sort(quick_fix.begin(), quick_fix.end(), [](const auto &first, const auto &second) {
        return first.second < second.second;
    });  // sort the quick_fix based on the loc

    std::rstrip(line);  // remove any trailing whitespace on the left side only

    for (auto &fixes : quick_fix) {
        fixes.first = fix_color(fixes.first);
    }

    // insert and change col if col > insert loc + len
    if (mark_pof) {
        std::string_insert(line, err_color, col);
        std::string_insert(line, ret_color, col + len + err_color.length());

        std::string_insert(marking, error_color(string(len, '^')), col);
    }

    if (quick_fix.empty()) {
        goto return_state;
    }

    while (!quick_fix.empty()) {
        auto  &fix        = quick_fix[0];
        size_t fix_length = fix.first.length() - (err_color.length() + ret_color.length());

        u64 insert_pos = fix.second;

        if (mark_pof && (insert_pos > col + err_color.length())) {  // inside the error section
            insert_pos += err_color.length();
            if (insert_pos + 1 > col + len + err_color.length()) {  // after the error section
                insert_pos += ret_color.length();

                if (did_add_inside_marked) {
                    insert_pos += 1;
                }
            } else {  // inside the marked section
                did_add_inside_marked = true;
                fix.first.replace(fix.first.find(ret_color), ret_color.length(), err_color);
            }
        }

        insert_mark(insert_pos,
                    fix.first,
                    did_add_inside_marked && !(fix.second > col + len + err_color.length()));
        line += " ";
        quick_fix.erase(quick_fix.begin());

        for (auto &remaining_fix : quick_fix) {
            remaining_fix.second += fix_length + (err_color.length() + ret_color.length());
        }
    }

return_state:
    line = bold_white(line);

    std::rstrip(line);
    std::rstrip(marking);

    line_typ = line_type{line_typ.first, {line_no, line, is_pof}};

    return marking;
}

size_t set_level(string &level, const double &err_code) {
    size_t      level_len  = 0;
    std::string _ret_color = "";

    switch (ERROR_MAP.at(static_cast<float>(err_code))->level) {
        case NOTE:
            level = string(colors::bold) + string(colors::fg8::cyan) + "note" + _ret_color;
            level_len =
                level.size() -
                string(string(colors::bold) + string(colors::fg8::cyan) + _ret_color).size();
            err_color = string(colors::effects::bold) + string(colors::fg8::cyan);
            break;
        case WARN:
            level = string(colors::bold) + string(colors::fg8::yellow) + "warn" + _ret_color;
            level_len =
                level.size() -
                string(string(colors::bold) + string(colors::fg8::yellow) + _ret_color).size();
            err_color = string(colors::effects::bold) + string(colors::fg8::yellow);
            break;
        case ERR:
            level =
                string(colors::bold) + _ret_color + string(colors::fg8::red) + "error" + _ret_color;
            level_len = level.size() - string(string(colors::bold) + _ret_color +
                                              string(colors::fg8::red) + _ret_color)
                                           .size();
            err_color = string(colors::effects::bold) + string(colors::fg8::red);
            break;
        case FATAL:
            level = string(colors::bold) + _ret_color + string(colors::fg8::red) + "fatal" +
                    string(colors::reset) + _ret_color;
            level_len = level.size() - string(string(colors::bold) + _ret_color +
                                              string(colors::fg8::red) + _ret_color)
                                           .size();
            err_color = string(colors::effects::bold) + string(colors::fg8::red);
            break;
        case NONE:
            break;
    }

    return level_len;
}

size_t set_level(string &level, const Level &err_level) {
    size_t      level_len   = 0;
    std::string __ret_color = "";

    switch (err_level) {
        case NOTE:
            level = string(colors::bold) + string(colors::fg8::cyan) + "note" + __ret_color;
            level_len =
                level.size() -
                string(string(colors::bold) + string(colors::fg8::cyan) + __ret_color).size();
            err_color = string(colors::effects::bold) + string(colors::fg8::cyan);
            break;
        case WARN:
            level = string(colors::bold) + string(colors::fg8::yellow) + "warn" + __ret_color;
            level_len =
                level.size() -
                string(string(colors::bold) + string(colors::fg8::yellow) + __ret_color).size();
            err_color = string(colors::effects::bold) + string(colors::fg8::yellow);
            break;
        case ERR:
            level = string(colors::bold) + __ret_color + string(colors::fg8::red) + "error" +
                    __ret_color;
            level_len = level.size() - string(string(colors::bold) + __ret_color +
                                              string(colors::fg8::red) + __ret_color)
                                           .size();
            err_color = string(colors::effects::bold) + string(colors::fg8::red);
            break;
        case FATAL:
            level = string(colors::bold) + __ret_color + string(colors::fg8::red) + "fatal" +
                    string(colors::reset) + __ret_color;
            level_len = level.size() - string(string(colors::bold) + __ret_color +
                                              string(colors::fg8::red) + __ret_color)
                                           .size();
            err_color = string(colors::effects::bold) + string(colors::fg8::red);
            break;
        default:
            break;
    }

    return level_len;
}

void normalize_namespace(std::string &str) {
    for (const auto &[key, value] : NAMESPACE_MAP) {
        std::size_t pos = 0;
        while ((pos = str.find(key, pos)) != std::string::npos) {
            str.replace(pos, key.length(), value);
            pos += value.length();
        }
    }
}

Panic::Panic(const CodeError &err)
    : level_len(err.level == NONE ? set_level(final_err.level, err.err_code)
                                  : set_level(final_err.level, err.level))
    , mark_pof(err.mark_pof) {
    auto err_map_at            = ERROR_MAP.at(static_cast<float>(err.err_code));
    bool internal_core_lib_err = false;

    if (err_map_at == std::nullopt) {
        throw std::runtime_error("err code \'" + std::to_string(err.err_code) + "\' not found");
    }

    HAS_ERRORED = HAS_ERRORED ? true
                              : ((err.level != NONE and err.level >= ERR) or
                                 (err.level == NONE and err_map_at->level >= ERR));

    final_err.color_mode = "16bit";
    final_err.error_type = "code";

    // if filename ends with $helix.core.lib remove it and mark the show error to be as a corelib
    // err (DEPRECATED - only here for backwards compatibility)
    if (err.pof->file_name().ends_with("$helix.core.lib")) {
        std::string recovered_f_name = err.pof->file_name();
        internal_core_lib_err        = true;

        recovered_f_name.erase(recovered_f_name.size() - std::string("$helix.core.lib").size(),
                               std::string("$helix.core.lib").size());
        final_err.file = recovered_f_name;
    } else {
        final_err.file = err.pof->file_name();
    }

    final_err.msg = err_map_at->err;
    if (!err.err_fmt_args.empty()) {
        final_err.msg = fmt_string(err_map_at->err, err.err_fmt_args);
    }

    /// iter over NAMESPACE_MAP's keys and see if final_err.msg contains any of the keys if so
    /// replace it with the value
    normalize_namespace(final_err.msg);

    final_err.fix = err_map_at->fix;
    if (!err.fix_fmt_args.empty()) {
        final_err.fix = fmt_string(err_map_at->fix, err.fix_fmt_args);
    }

    final_err.line   = err.pof->line_number();
    final_err.col    = err.pof->column_number();
    final_err.offset = err.pof->length();
    final_err.indent = err.indent;

    process_full_line();

    if (!err.opt_fixes.empty()) {
        for (const auto &fix_pos_pair : err.opt_fixes) {
            final_err.quick_fix.emplace_back(fix_pos_pair.first.value(),
                                             calculate_addition_pos(fix_pos_pair.second));
        }
    }

    if (!internal_core_lib_err) {
        ERRORS.push_back(final_err);
    }

    if (SHOW_ERROR) {
        show_error(internal_core_lib_err);
    }
}

Panic::Panic(const CompilerError &err)
    : level_len(set_level(final_err.level, err.err_code)) {
    auto err_map_at = ERROR_MAP.at(static_cast<float>(err.err_code));

    if (err_map_at == std::nullopt) {
        print("err code \'" + std::to_string(err.err_code) + "\' not found");
        throw std::runtime_error("err code \'" + std::to_string(err.err_code) + "\' not found");
    }

    if (err_map_at->level >= ERR) {
        HAS_ERRORED = true;
    }

    final_err.color_mode = "16bit";
    final_err.error_type = "compiler";

    final_err.msg = err_map_at->err;
    if (!err.err_fmt_args.empty()) {
        final_err.msg = fmt_string(err_map_at->err, err.err_fmt_args);
    }

    final_err.fix = err_map_at->fix;
    if (!err.fix_fmt_args.empty()) {
        final_err.fix = fmt_string(err_map_at->fix, err.fix_fmt_args);
    }

    this->mark_pof = false;

    final_err.line   = 0;
    final_err.col    = 0;
    final_err.offset = 0;

    ERRORS.push_back(final_err);

    if (SHOW_ERROR) {
        show_error(false);
    }
}

void Panic::process_full_line() {
    auto full_line = __CONTROLLER_FS_N::get_line(final_err.file, final_err.line);

    if (!full_line.has_value()) {
        final_err.full_line = "$ out of bounds $";
        final_err.line      = 1;
        return;
    }

    while (!full_line->empty() && full_line->back() == ' ') {  // trim trailing spaces
        full_line->pop_back();
    }

    final_err.full_line = full_line.value();
}

u32 Panic::calculate_addition_pos(i64 pos) const {
    if (pos < 0) {
        pos = static_cast<i64>(final_err.full_line.size() /* remove term */) + (pos + 1);
    }

    if (pos < 0) {
        pos = 0;
    }

    return static_cast<u32>(pos);
}

void Panic::show_error(bool internal_core_lib_err) {
    if (final_err.error_type == "compiler") {
        /// needs to print: level: msg
        std::string formatted_error;

        formatted_error += final_err.level + ": " + final_err.msg + string(colors::reset);

        if (!final_err.fix.empty()) {
            formatted_error += "\n" + string(colors::bold) + string(colors::fg8::green) + "fix" +
                               ": " + std::string(colors::reset) + final_err.fix;
        }

        formatted_error += string(colors::reset);

        print_err(formatted_error);
        std::exit(1);

        return;
    }

    lines_vec lines;
    if (final_err.full_line != "$ out of bounds $") {
        lines = get_surrounding_lines(final_err.file, final_err.line);
    }

    string markings;
    string formatted_error;
    string whitespace = string(level_len, ' ');
    string A_W;  // additional_whitespace

    auto generate_left_side = [&](string align) -> string {
        std::strip(align);

        if (align.size() > level_len) {
            A_W = string((align.size() - level_len) + 1, ' ');
        }

        int line_no = std::stoi(align);

        std::ostringstream temp_out;
        temp_out << std::setw(static_cast<int>(whitespace.size() + A_W.size() - 1)) << line_no
                 << " ";

        return temp_out.str();
    };

    // first make sure theres enough padding for all the line numbers
    for (auto line : lines) {
        generate_left_side(std::get<0>(line.second));
    }

    // identify all the blank lines
    auto it = lines.begin();

    while (it != lines.end()) {
        auto &line         = *it;
        auto &line_content = std::get<1>(line.second);

        // Check if the current line is blank
        if (line_content.empty()) {
            auto   next_it     = std::next(it);  // safer alternative to it + 1
            size_t blank_count = 1;

            // Count consecutive blank lines
            while (next_it != lines.end() && std::get<1>(next_it->second).empty()) {
                blank_count++;
                next_it++;
            }

            // If more than two consecutive blank lines, set the flag
            if (blank_count >= 2) {
                line.first = true;
            }

            // Keep only one blank line if more than one consecutive blank lines
            if (blank_count > 1) {
                // Use `erase` and update the iterator
                it = lines.erase(std::next(it), next_it);  // safely erase using `next_it`
            } else {
                ++it;
            }
        } else {
            ++it;
        }
    }

    // add the message
    formatted_error += A_W + final_err.level + ": " + std::string(colors::reset) + final_err.msg +
                       string(colors::reset) + "\n";  // fatal: missing semicolon
    formatted_error += A_W + string(level_len - 1, ' ') + "-->  at " +
                       format_loc_info((internal_core_lib_err ? "helix.core.lib" : final_err.file),
                                       final_err.line,
                                       final_err.col) +
                       "\n";

    string left_side;

    for (auto line : lines) {
        left_side = generate_left_side(std::get<0>(line.second));

        if (std::get<2>(line.second)) {
            markings = A_W + whitespace + ": ";
            markings += color_and_mark(
                line, final_err.col, final_err.offset, final_err.quick_fix, mark_pof);

            formatted_error +=
                left_side + "| " + std::get<1>(line.second) + string(colors::reset) + "\n";
            formatted_error += markings + string(colors::reset) + "\n";
        } else if (line.first) {
            formatted_error += string((A_W.size() + whitespace.size() - 1), ' ') + "···" + "\n";
        } else {
            formatted_error += left_side + "| " + std::get<1>(line.second) + "\n";
        }
    }

    if (!final_err.fix.empty()) {
        formatted_error += A_W + whitespace + "| " + "\n";
        formatted_error += string((A_W.size() + whitespace.size() - 3), ' ') +
                           string(colors::bold) + string(colors::fg8::green) + "fix" + ": " +
                           std::string(colors::reset) + final_err.fix + "\n";
    }

    formatted_error += string(colors::reset);

    // split the formatted_error by \n and add final_err.indent to each line
    if (final_err.indent > 0) {
        std::vector<std::string> lines_to_indent;
        std::istringstream       iss(formatted_error);
        std::string              line;

        while (std::getline(iss, line)) {
            lines_to_indent.push_back(line);
        }

        for (auto &line : lines_to_indent) {
            std::string_insert(line, std::string(final_err.indent * 4, ' '), 0);
        }

        formatted_error = std::accumulate(
            lines_to_indent.begin(),
            lines_to_indent.end(),
            std::string(),
            [](const std::string &a, const std::string &b) { return a + b + "\n"; });

        formatted_error.pop_back();  // remove the last newline
    }

    print_err(formatted_error);
}
}  // namespace error

// │ : ː ╭ ─ >
#undef LINES_TO_SHOW