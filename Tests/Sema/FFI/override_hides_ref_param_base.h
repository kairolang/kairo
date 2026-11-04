#pragma once
namespace ob {
struct Opts {};
struct Pre {};
struct Consumer {
    virtual ~Consumer() {}
    virtual void Begin(const Opts &, const Pre * = nullptr) {}
    virtual void Fill(Opts &out, int = 0) {}
    virtual void Take(Opts &&o) {}
};
}
