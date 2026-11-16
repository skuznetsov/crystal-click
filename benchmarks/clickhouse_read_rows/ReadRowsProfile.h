#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>

namespace DB::ReadRowsProfile
{

using Clock = std::chrono::steady_clock;

struct WorkerCounters
{
    std::uint64_t start_ns = 0;
    std::uint64_t end_ns = 0;

    std::uint64_t transport_ns = 0;
    std::uint64_t transport_calls = 0;
    std::uint64_t transport_bytes = 0;

    std::uint64_t checksum_ns = 0;
    std::uint64_t checksum_calls = 0;

    std::uint64_t lz4_ns = 0;
    std::uint64_t lz4_calls = 0;

    std::uint64_t materialize_copy_ns = 0;
    std::uint64_t materialize_copy_calls = 0;
    std::uint64_t materialize_copy_bytes = 0;
    std::uint64_t direct_decode_calls = 0;
    std::uint64_t direct_decode_bytes = 0;

    std::uint64_t output_copy_ns = 0;
    std::uint64_t output_copy_calls = 0;
    std::uint64_t output_copy_bytes = 0;

    std::uint64_t open_ns = 0;
    std::uint64_t open_calls = 0;
    std::uint64_t fstat_ns = 0;
    std::uint64_t fstat_calls = 0;
    std::uint64_t close_ns = 0;
    std::uint64_t close_calls = 0;
};

enum class Operation
{
    Transport,
    Checksum,
    LZ4,
    MaterializeCopy,
    OutputCopy,
    Open,
    FStat,
    Close,
};

struct ThreadState
{
    WorkerCounters * counters = nullptr;
};

inline thread_local ThreadState thread_state;

inline std::uint64_t elapsedNs(Clock::time_point start, Clock::time_point end)
{
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count());
}

inline std::uint64_t offsetNs(Clock::time_point scan_started)
{
    return elapsedNs(scan_started, Clock::now());
}

class WorkerScope
{
public:
    WorkerScope(WorkerCounters & counters_, Clock::time_point scan_started_)
        : counters(counters_), previous(thread_state), scan_started(scan_started_)
    {
        counters.start_ns = offsetNs(scan_started);
        thread_state = ThreadState{&counters};
    }

    ~WorkerScope()
    {
        counters.end_ns = offsetNs(scan_started);
        thread_state = previous;
    }

    WorkerScope(const WorkerScope &) = delete;
    WorkerScope & operator=(const WorkerScope &) = delete;

private:
    WorkerCounters & counters;
    ThreadState previous;
    Clock::time_point scan_started;
};

class Timer
{
public:
    explicit Timer(Operation operation_)
        : counters(thread_state.counters)
        , operation(operation_)
    {
        if (counters)
            started = Clock::now();
    }

    ~Timer() { finish(); }

    Timer(const Timer &) = delete;
    Timer & operator=(const Timer &) = delete;

    void finish()
    {
        if (!counters)
            return;

        const std::uint64_t duration = elapsedNs(started, Clock::now());
        switch (operation)
        {
            case Operation::Transport:
                counters->transport_ns += duration;
                ++counters->transport_calls;
                break;
            case Operation::Checksum:
                counters->checksum_ns += duration;
                ++counters->checksum_calls;
                break;
            case Operation::LZ4:
                counters->lz4_ns += duration;
                ++counters->lz4_calls;
                break;
            case Operation::MaterializeCopy:
                counters->materialize_copy_ns += duration;
                ++counters->materialize_copy_calls;
                break;
            case Operation::OutputCopy:
                counters->output_copy_ns += duration;
                ++counters->output_copy_calls;
                break;
            case Operation::Open:
                counters->open_ns += duration;
                ++counters->open_calls;
                break;
            case Operation::FStat:
                counters->fstat_ns += duration;
                ++counters->fstat_calls;
                break;
            case Operation::Close:
                counters->close_ns += duration;
                ++counters->close_calls;
                break;
        }
        counters = nullptr;
    }

private:
    WorkerCounters * counters;
    Operation operation;
    Clock::time_point started{};
};

inline void addTransportBytes(std::size_t bytes)
{
    if (thread_state.counters)
        thread_state.counters->transport_bytes += bytes;
}

inline void addMaterializeCopyBytes(std::size_t bytes)
{
    if (thread_state.counters)
        thread_state.counters->materialize_copy_bytes += bytes;
}

inline void addDirectDecode(std::size_t bytes)
{
    if (!thread_state.counters)
        return;
    ++thread_state.counters->direct_decode_calls;
    thread_state.counters->direct_decode_bytes += bytes;
}

inline void addOutputCopyBytes(std::size_t bytes)
{
    if (thread_state.counters)
        thread_state.counters->output_copy_bytes += bytes;
}

} // namespace DB::ReadRowsProfile
