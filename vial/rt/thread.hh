///--- The Helix Project ------------------------------------------------------------------------///
///                                                                                              ///
///   Part of the Helix Project, under the Attribution 4.0 International license (CC BY 4.0).    ///
///   You are allowed to use, modify, redistribute, and create derivative works, even for        ///
///   commercial purposes, provided that you give appropriate credit, and indicate if changes    ///
///   were made.                                                                                 ///
///                                                                                              ///
///   For more information on the license terms and requirements, please visit:                  ///
///     https://creativecommons.org/licenses/by/4.0/                                             ///
///                                                                                              ///
///   SPDX-License-Identifier: CC-BY-4.0                                                         ///
///   Copyright (c) 2024 The Helix Project (CC BY 4.0)                                           ///
///                                                                                              ///
///-------------------------------------------------------------------------------------- C++ ---///

#ifndef __THREAD_H__
#define __THREAD_H__

/// uncomment only for lsp support otherwise there will be build errors.
#include "/Volumes/Development/Projects/Helix/helix-lang/build/release/arm64-macosx-llvm/core/include/core.hh"

#include <atomic>
#include <condition_variable>
#include <functional>
#include <future>
#include <mutex>
#include <queue>
#include <thread>
#include <vector>

namespace helix {

class ThreadPool {
  public:
    explicit ThreadPool(usize thread_count = libcxx::thread::hardware_concurrency());
    ~ThreadPool();

    ThreadPool(const ThreadPool &)            = delete;
    ThreadPool &operator=(const ThreadPool &) = delete;

    // Disable move semantics
    ThreadPool(ThreadPool &&)            = delete;
    ThreadPool &operator=(ThreadPool &&) = delete;

    template <typename Func, typename... Args>
    auto submit(Func &&f, Args &&...args) -> libcxx::future<libcxx::invoke_result_t<Func, Args...>>;

  private:
    using Task = libcxx::function<void()>;

    void worker_loop();

    libcxx::vector<libcxx::thread> workers_;
    libcxx::queue<Task>            tasks_;
    libcxx::mutex                  queue_mutex_;
    libcxx::condition_variable     condition_;
    libcxx::atomic<bool>           stop_;
};

inline ThreadPool::ThreadPool(usize thread_count)
    : stop_(false) {
    thread_count = (thread_count == 0) ? 1 : thread_count;
    workers_.reserve(thread_count);
    for (usize i = 0; i < thread_count; ++i) {
        workers_.emplace_back([this] { worker_loop(); });
    }
}

inline ThreadPool::~ThreadPool() {
    stop_.store(true, libcxx::memory_order_release);
    condition_.notify_all();
    for (auto &thread : workers_) {
        if (thread.joinable()) {
            thread.join();
        }
    }
}

inline void ThreadPool::worker_loop() {
    while (!stop_.load(libcxx::memory_order_acquire)) {
        Task task;
        {
            libcxx::unique_lock<libcxx::mutex> lock(queue_mutex_);
            condition_.wait(
                lock, [this] { return stop_.load(libcxx::memory_order_relaxed) || !tasks_.empty(); });

            if (stop_.load(libcxx::memory_order_relaxed) && tasks_.empty()) {
                return;
            }

            task = libcxx::move(tasks_.front());
            tasks_.pop();
        }
        task();
    }
}

template <typename Func, typename... Args>
auto ThreadPool::submit(Func &&f, Args &&...args)
    -> libcxx::future<libcxx::invoke_result_t<Func, Args...>> {
    using ReturnType = libcxx::invoke_result_t<Func, Args...>;

    auto bound    = libcxx::bind(libcxx::forward<Func>(f), libcxx::forward<Args>(args)...);
    auto task_ptr = libcxx::make_shared<libcxx::packaged_task<ReturnType()>>(libcxx::move(bound));

    {
        libcxx::lock_guard<libcxx::mutex> lock(queue_mutex_);
        if (stop_.load(libcxx::memory_order_relaxed)) {
            throw libcxx::runtime_error("ThreadPool is stopped");
        }

        tasks_.emplace([task_ptr]() { (*task_ptr)(); });
    }

    condition_.notify_one();
    return task_ptr->get_future();
}

}  // namespace helix

#endif // __THREAD_H__