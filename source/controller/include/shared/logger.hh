#ifndef __KAIRO_LOGGER_H__
#define __KAIRO_LOGGER_H__

#include <neo-pprint/include/ansi_colors.hh>
#include <neo-pprint/include/hxpprint.hh>

inline bool NO_LOGS = false;

enum class LogLevel { Debug, Info, Warning, Error, Progress };

namespace kairo {
template <LogLevel l, typename... Args>
void log(Args &&...args) {
    std::string prefix;

    if (NO_LOGS) {
        return;
    }

    if constexpr (l == LogLevel::Debug) {
        prefix = std::string(colors::fg16::gray) + "debug: ";
    } else if constexpr (l == LogLevel::Info) {
        prefix = std::string(colors::fg16::green) + "info: ";
    } else if constexpr (l == LogLevel::Warning) {
        prefix = std::string(colors::fg16::yellow) + "warning: ";
    } else if constexpr (l == LogLevel::Error) {
        prefix = std::string(colors::fg16::red) + "error: ";
    } else if constexpr (l == LogLevel::Progress) {
        prefix = std::string(colors::fg16::cyan) + "[" + std::string(colors::reset);
        std::string postfix = std::string(colors::fg16::cyan) + "]" + std::string(colors::reset);
        print_pinned(prefix, std::forward<Args>(args)..., postfix);
        return;
    }

    print(prefix, std::string(colors::reset), std::forward<Args>(args)...);
}

template <LogLevel l, typename... Args>
void log_opt(bool enable, Args &&...args) {
    std::string prefix;

    if (!enable || NO_LOGS) {
        return;
    }

    if constexpr (l == LogLevel::Debug) {
        prefix = std::string(colors::fg16::gray) + "debug: ";
    } else if constexpr (l == LogLevel::Info) {
        prefix = std::string(colors::fg16::green) + "info: ";
    } else if constexpr (l == LogLevel::Warning) {
        prefix = std::string(colors::fg16::yellow) + "warning: ";
    } else if constexpr (l == LogLevel::Error) {
        prefix = std::string(colors::fg16::red) + "error: ";
    } else if constexpr (l == LogLevel::Progress) {
        prefix = std::string(colors::fg16::cyan) + "[" + std::string(colors::reset);
        std::string postfix = std::string(colors::fg16::cyan) + "]" + std::string(colors::reset);
        print_pinned(prefix, std::forward<Args>(args)..., postfix);
        return;
    }

    print("\r", prefix, std::string(colors::reset), std::forward<Args>(args)..., "\r");
}
}  // namespace kairo

#endif  // __KAIRO_LOGGER_H__