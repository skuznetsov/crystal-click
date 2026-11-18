#pragma once

#include <config.h>

#include <cstdint>
#include <stdexcept>

#if defined(__APPLE__) && !USE_JEMALLOC
#include <atomic>
#include <dlfcn.h>
#endif

/// Optional process-wide request counters for the macOS system allocator.
/// The latency run leaves the logger uninstalled.
class NativeReadAllocations
{
public:
    struct Counts
    {
        uint64_t requests = 0;
        uint64_t bytes = 0;
    };

    explicit NativeReadAllocations(bool enabled)
    {
        if (!enabled)
            return;
#if defined(__APPLE__) && !USE_JEMALLOC
        logger_slot = reinterpret_cast<Logger *>(dlsym(RTLD_DEFAULT, "malloc_logger"));
        if (!logger_slot || __atomic_load_n(logger_slot, __ATOMIC_ACQUIRE))
            throw std::runtime_error("system malloc_logger is unavailable or already in use");
        __atomic_store_n(logger_slot, observeAllocation, __ATOMIC_RELEASE);
#else
        throw std::runtime_error("native allocation counts require the macOS system allocator");
#endif
    }

    NativeReadAllocations(const NativeReadAllocations &) = delete;
    NativeReadAllocations & operator=(const NativeReadAllocations &) = delete;

    ~NativeReadAllocations()
    {
#if defined(__APPLE__) && !USE_JEMALLOC
        if (logger_slot)
            __atomic_store_n(logger_slot, nullptr, __ATOMIC_RELEASE);
#endif
    }

    Counts snapshot() const
    {
#if defined(__APPLE__) && !USE_JEMALLOC
        if (logger_slot)
            return {requests.load(std::memory_order_relaxed), bytes.load(std::memory_order_relaxed)};
#endif
        return {};
    }

private:
#if defined(__APPLE__) && !USE_JEMALLOC
    using Logger = void (*)(uint32_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uint32_t);

    static void observeAllocation(uint32_t type, uintptr_t, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t)
    {
        // libmalloc flags: allocate = 2, deallocate = 4. Realloc sets both
        // and passes the new request size in the third argument.
        constexpr uint32_t allocate = 2;
        constexpr uint32_t deallocate = 4;
        if ((type & allocate) && result)
        {
            requests.fetch_add(1, std::memory_order_relaxed);
            bytes.fetch_add(type & deallocate ? arg3 : arg2, std::memory_order_relaxed);
        }
    }

    inline static std::atomic<uint64_t> requests{0};
    inline static std::atomic<uint64_t> bytes{0};
    Logger * logger_slot = nullptr;
#endif
};
