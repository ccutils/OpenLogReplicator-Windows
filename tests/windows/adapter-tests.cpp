// Contract tests for OS adaptation, not tests of redo interpretation.
#define FALSE 0
#define TRUE 1
#include <winioctl.h>
#undef FALSE
#undef TRUE
#include <iostream>
#include <vector>
#include <atomic>
#include "../../src/common/exception/DataException.h"
#include "../../src/common/exception/RuntimeException.h"

static void require(bool ok, const char* message) {
    if (!ok) { std::cerr << "FAIL: " << message << " errno=" << errno << '\n'; exit(1); }
}

int main() {
    char temporary[MAX_PATH];
    require(GetTempPathA(MAX_PATH, temporary) != 0, "temporary directory");
    const std::string directory = std::string(temporary) + "olr-adapter-" + std::to_string(GetCurrentProcessId());
    require(CreateDirectoryA(directory.c_str(), nullptr) != 0, "isolated test directory");
    const std::string path = directory + "/bytes.bin";
    int fd = olrOpen(path.c_str(), O_CREAT | O_RDWR | O_EXCL, S_IRUSR | S_IWUSR);
    require(fd >= 0, "open binary");
    DWORD ignored;
    require(DeviceIoControl(reinterpret_cast<HANDLE>(_get_osfhandle(fd)), FSCTL_SET_SPARSE,
        nullptr, 0, nullptr, 0, &ignored, nullptr) != 0, "sparse file");
    const uint8_t bytes[] = {0, 10, 13, 26, 128, 255};
    constexpr int64_t offset = (int64_t{1} << 32) + 123;
    require(write(fd, bytes, sizeof(bytes)) == sizeof(bytes), "binary write");
    require(pwrite(fd, bytes, sizeof(bytes), offset) == sizeof(bytes), ">4GiB pwrite");
    require(lseek(fd, 0, SEEK_CUR) == sizeof(bytes), "pwrite preserves file cursor");
    uint8_t observed[sizeof(bytes)]{};
    require(pread(fd, observed, sizeof(observed), offset) == sizeof(observed), ">4GiB pread");
    require(memcmp(bytes, observed, sizeof(bytes)) == 0, "all bytes preserved");
    require(lseek(fd, 0, SEEK_CUR) == sizeof(bytes), "pread preserves file cursor");
    struct stat info{};
    require(stat(path.c_str(), &info) == 0 && info.st_size == offset + sizeof(bytes), "64-bit stat");

    std::atomic<bool> consistent{true};
    std::vector<std::thread> workers;
    for (int i = 0; i < 8; ++i) workers.emplace_back([&, i] {
        uint64_t value = static_cast<uint64_t>(i + 1), result = 0;
        for (int j = 0; j < 1000; ++j) {
            if (pwrite(fd, &value, sizeof(value), 4096 + i * 64) != sizeof(value) ||
                pread(fd, &result, sizeof(result), 4096 + i * 64) != sizeof(result) || value != result) consistent = false;
        }
    });
    for (auto& worker : workers) worker.join();
    require(consistent, "concurrent positional IO");

    require(flock(fd, LOCK_EX | LOCK_NB) == 0, "first advisory lock");
    const int second = olrOpen(path.c_str(), O_RDONLY);
    require(second >= 0 && read(second, observed, sizeof(observed)) == sizeof(observed), "lock permits config reload reads");
    require(flock(second, LOCK_EX | LOCK_NB) == -1, "duplicate instance rejected");
    require(close(fd) == 0, "close releases lock");
    require(flock(second, LOCK_EX | LOCK_NB) == 0, "lock recoverable after close");
    require(close(second) == 0, "second close");
    require(truncate(path.c_str(), offset) == 0 && stat(path.c_str(), &info) == 0 && info.st_size == offset, "64-bit swap truncation");
    require(pread(-1, observed, 1, 0) == -1, "invalid descriptor reports failure");
    require(olrOpen((directory + "/missing").c_str(), O_RDONLY) == -1, "missing file reports failure");

    void* memory = olr_windows::alignedAllocate(4096, 16384);
    require(memory && reinterpret_cast<uintptr_t>(memory) % 4096 == 0, "aligned allocation");
    olr_windows::alignedRelease(memory);
    timeval now{}; require(gettimeofday(&now, nullptr) == 0, "clock");
    require(std::llabs(now.tv_sec - static_cast<int64_t>(time(nullptr))) <= 2, "64-bit UTC clock");
    require(ffsll(0) == 0 && ffsll(1) == 1 && ffsll(INT64_MIN) == 64, "bit scan boundary contract");
    for (unsigned i = 0; i < 64; ++i) require(ffsll(static_cast<int64_t>(uint64_t{1} << i)) == i + 1, "bit scan positions");
    try { throw OpenLogReplicator::DataException(123, std::string(4000, 'x')); }
    catch (const OpenLogReplicator::DataException& error) { require(error.code == 123 && error.msg.size() == 4000, "exception transport"); }
    try { throw OpenLogReplicator::RuntimeException(456, std::string(4000, 'y'), 789); }
    catch (const OpenLogReplicator::RuntimeException& error) { require(error.code == 456 && error.supCode == 789 && error.msg.size() == 4000, "runtime exception transport"); }
    DIR* entries = opendir(directory.c_str()); require(entries != nullptr, "directory enumeration");
    bool found = false;
    while (auto* entry = readdir(entries)) if (std::string(entry->d_name) == "bytes.bin") found = true;
    require(found && closedir(entries) == 0, "directory entry names");
    require(unlink(path.c_str()) == 0 && unlink((path + ".lock").c_str()) == 0, "test files cleanup");
    require(RemoveDirectoryA(directory.c_str()) != 0, "test directory cleanup");
    std::cout << "PASS: binary IO, >4GiB offsets/truncate, concurrent IO, advisory lock, memory, clock, bit scan, exceptions, directory\n";
    return 0;
}
