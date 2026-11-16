// Windows operating-system adapter. GPL-3.0-or-later, same as upstream.
#pragma once
#ifndef _WIN32
#error Windows adapter included on another platform
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <process.h>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <ctime>
#include <string>
#include <thread>
#include <mutex>
#include <chrono>
#include <array>
#include <unordered_map>
#include <malloc.h>
#include <intrin.h>
#undef ERROR
#undef TRANSPARENT
#undef DELETE
#undef EMPTY
#undef NO_ERROR
#undef ERROR_CRC
#undef FALSE
#undef TRUE
using uint = unsigned int;

// Compiler syntax only; never redefine parser arithmetic or integer widths.
#ifdef _MSC_VER
#define __attribute__(x)
#define __builtin_expect(x, expected) (x)
#define __builtin_prefetch(address, rw, locality) _mm_prefetch(reinterpret_cast<const char*>(address), _MM_HINT_NTA)
#endif
#define tzset _tzset
#define timezone _timezone
#ifndef S_ISDIR
#define S_ISDIR(mode) (((mode) & _S_IFMT) == _S_IFDIR)
#define S_ISREG(mode) (((mode) & _S_IFMT) == _S_IFREG)
#define S_IRUSR _S_IREAD
#define S_IWUSR _S_IWRITE
#endif
using ssize_t = int64_t;

namespace olr_windows {
inline void setError(DWORD code) {
    switch (code) {
    case ERROR_FILE_NOT_FOUND: case ERROR_PATH_NOT_FOUND: errno = ENOENT; break;
    case ERROR_ACCESS_DENIED: errno = EACCES; break;
    case ERROR_SHARING_VIOLATION: case ERROR_LOCK_VIOLATION: errno = EAGAIN; break;
    case ERROR_DISK_FULL: errno = ENOSPC; break;
    case ERROR_INVALID_HANDLE: errno = EBADF; break;
    case ERROR_ALREADY_EXISTS: case ERROR_FILE_EXISTS: errno = EEXIST; break;
    case ERROR_NOT_ENOUGH_MEMORY: errno = ENOMEM; break;
    default: errno = EIO; break;
    }
}
inline std::wstring wide(const char* text) {
    const int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, nullptr, 0);
    if (!n) { errno = EINVAL; return {}; }
    std::wstring result(n, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, result.data(), n);
    result.pop_back();
    return result;
}
inline std::mutex positionalIo;
inline std::mutex fileLocksMutex;
inline std::unordered_map<int, HANDLE> fileLocks;
inline void* alignedAllocate(size_t alignment, size_t size) { return _aligned_malloc(size, alignment); }
inline void alignedRelease(void* address) { _aligned_free(address); }
}

inline int olrOpen(const char* path, int flags, int = 0) {
    const auto name = olr_windows::wide(path);
    if (name.empty()) return -1;
    DWORD access = (flags & O_RDWR) ? GENERIC_READ | GENERIC_WRITE :
        ((flags & O_WRONLY) ? GENERIC_WRITE : GENERIC_READ);
    DWORD creation = (flags & O_CREAT) ? ((flags & O_EXCL) ? CREATE_NEW :
        ((flags & O_TRUNC) ? CREATE_ALWAYS : OPEN_ALWAYS)) :
        ((flags & O_TRUNC) ? TRUNCATE_EXISTING : OPEN_EXISTING);
    HANDLE handle = CreateFileW(name.c_str(), access, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, creation, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle == INVALID_HANDLE_VALUE) { olr_windows::setError(GetLastError()); return -1; }
    const int fd = _open_osfhandle(reinterpret_cast<intptr_t>(handle), flags | _O_BINARY);
    if (fd < 0) CloseHandle(handle);
    return fd;
}
inline int close(int fd) {
    {
        std::lock_guard<std::mutex> guard(olr_windows::fileLocksMutex);
        auto found = olr_windows::fileLocks.find(fd);
        if (found != olr_windows::fileLocks.end()) {
            CloseHandle(found->second);
            olr_windows::fileLocks.erase(found);
        }
    }
    return _close(fd);
}
inline int truncate(const char* path, int64_t length) {
    const int fd = olrOpen(path, O_WRONLY);
    if (fd < 0) return -1;
    const errno_t error = _chsize_s(fd, length);
    const int closeResult = close(fd);
    if (error) { errno = error; return -1; }
    return closeResult;
}
inline int read(int fd, void* data, unsigned size) { return _read(fd, data, size); }
inline int write(int fd, const void* data, unsigned size) { return _write(fd, data, size); }
#define lseek _lseeki64
constexpr int STDOUT_FILENO = 1;
inline int pread(int fd, void* data, unsigned size, int64_t offset) {
    if (fd < 0 || offset < 0) { errno = fd < 0 ? EBADF : EINVAL; return -1; }
    std::lock_guard<std::mutex> guard(olr_windows::positionalIo);
    const auto saved = _lseeki64(fd, 0, SEEK_CUR);
    if (saved < 0 || _lseeki64(fd, offset, SEEK_SET) < 0) return -1;
    const int count = _read(fd, data, size);
    const int savedError = errno;
    const auto restored = _lseeki64(fd, saved, SEEK_SET);
    if (count < 0) errno = savedError;
    else if (restored < 0) return -1;
    return count;
}
inline int pwrite(int fd, const void* data, unsigned size, int64_t offset) {
    if (fd < 0 || offset < 0) { errno = fd < 0 ? EBADF : EINVAL; return -1; }
    std::lock_guard<std::mutex> guard(olr_windows::positionalIo);
    const auto saved = _lseeki64(fd, 0, SEEK_CUR);
    if (saved < 0 || _lseeki64(fd, offset, SEEK_SET) < 0) return -1;
    const int count = _write(fd, data, size);
    const int savedError = errno;
    const auto restored = _lseeki64(fd, saved, SEEK_SET);
    if (count < 0) errno = savedError;
    else if (restored < 0) return -1;
    return count;
}
inline int unlink(const char* path) {
    auto name = olr_windows::wide(path);
    if (!name.empty() && DeleteFileW(name.c_str())) return 0;
    olr_windows::setError(GetLastError()); return -1;
}
inline int usleep(uint64_t micros) {
    std::this_thread::sleep_for(std::chrono::microseconds(micros)); return 0;
}

// No POSIX privilege model on Windows; installation scripts manage ACLs.
inline int geteuid() { return -1; }
constexpr int LOCK_EX = 2;
constexpr int LOCK_NB = 4;
inline int flock(int fd, int operation) {
    if (operation != (LOCK_EX | LOCK_NB)) { errno = EINVAL; return -1; }
    std::lock_guard<std::mutex> guard(olr_windows::fileLocksMutex);
    if (olr_windows::fileLocks.count(fd)) return 0;
    // Lock a sidecar: a Windows byte lock on the config itself would also
    // prevent checkpoint/config-reload reads. POSIX flock is advisory.
    wchar_t path[32768];
    const DWORD n = GetFinalPathNameByHandleW(reinterpret_cast<HANDLE>(_get_osfhandle(fd)), path, 32768, FILE_NAME_NORMALIZED);
    if (!n || n >= 32768) { errno = EIO; return -1; }
    std::wstring lockPath(path); lockPath += L".lock";
    HANDLE lock = CreateFileW(lockPath.c_str(), GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (lock == INVALID_HANDLE_VALUE) { olr_windows::setError(GetLastError()); return -1; }
    OVERLAPPED position{};
    if (LockFileEx(lock, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &position)) {
        olr_windows::fileLocks.emplace(fd, lock); return 0;
    }
    const auto error = GetLastError(); CloseHandle(lock);
    olr_windows::setError(error); return -1;
}

struct olr_stat64 : _stat64 {};
inline int olr_stat64(const char* path, struct olr_stat64* result) {
    const auto name = olr_windows::wide(path);
    if (name.empty()) return -1;
    return _wstat64(name.c_str(), result);
}
#define stat olr_stat64
inline int ffsll(int64_t value) {
    unsigned long index;
    return _BitScanForward64(&index, static_cast<uint64_t>(value)) ? static_cast<int>(index + 1) : 0;
}

// gettimeofday uses signed 64-bit seconds, unlike Winsock's 32-bit timeval.
struct timeval { int64_t tv_sec; int64_t tv_usec; };
inline int gettimeofday(timeval* value, void*) {
    FILETIME fileTime;
    GetSystemTimePreciseAsFileTime(&fileTime); // Windows 8 / Server 2012
    ULARGE_INTEGER ticks;
    ticks.LowPart = fileTime.dwLowDateTime; ticks.HighPart = fileTime.dwHighDateTime;
    const int64_t micros = static_cast<int64_t>(ticks.QuadPart / 10) - 11644473600000000LL;
    value->tv_sec = micros / 1000000; value->tv_usec = micros % 1000000;
    return 0;
}

using pthread_t = std::thread*;
inline pthread_t pthread_self() { return reinterpret_cast<pthread_t>(static_cast<uintptr_t>(GetCurrentThreadId())); }
inline int pthread_create(pthread_t* thread, void*, void* (*entry)(void*), void* argument) {
    try { *thread = new std::thread([entry, argument] { entry(argument); }); return 0; }
    catch (...) { return EAGAIN; }
}
inline int pthread_join(pthread_t thread, void**) {
    if (!thread) return EINVAL;
    thread->join(); delete thread; return 0;
}

struct dirent { char d_name[32768]; };
struct DIR { HANDLE handle{INVALID_HANDLE_VALUE}; WIN32_FIND_DATAW data{}; bool first{true}; dirent entry{}; };
inline DIR* opendir(const char* path) {
    auto name = olr_windows::wide(path);
    if (name.empty()) return nullptr;
    const auto attrs = GetFileAttributesW(name.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY)) { errno = ENOENT; return nullptr; }
    name += L"\\*";
    auto* directory = new DIR;
    directory->handle = FindFirstFileW(name.c_str(), &directory->data);
    if (directory->handle == INVALID_HANDLE_VALUE) {
        const auto error = GetLastError();
        if (error == ERROR_FILE_NOT_FOUND) { directory->first = false; return directory; }
        delete directory; olr_windows::setError(error); return nullptr;
    }
    return directory;
}
inline dirent* readdir(DIR* directory) {
    if (directory->handle == INVALID_HANDLE_VALUE) return nullptr;
    if (!directory->first && !FindNextFileW(directory->handle, &directory->data)) {
        if (GetLastError() != ERROR_NO_MORE_FILES) olr_windows::setError(GetLastError());
        return nullptr;
    }
    directory->first = false;
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, directory->data.cFileName, -1,
        directory->entry.d_name, sizeof(directory->entry.d_name), nullptr, nullptr)) { errno = EILSEQ; return nullptr; }
    return &directory->entry;
}
inline int closedir(DIR* directory) {
    const bool ok = directory->handle == INVALID_HANDLE_VALUE || FindClose(directory->handle);
    delete directory; return ok ? 0 : -1;
}
struct utsname { char machine[32]{"x86_64"}; char sysname[32]{"Windows"}; char release[64]{}; };
inline int uname(utsname* name) {
    using RtlGetVersionFn = LONG (WINAPI*)(OSVERSIONINFOW*);
    auto versionFn = reinterpret_cast<RtlGetVersionFn>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion"));
    OSVERSIONINFOW version{}; version.dwOSVersionInfoSize = sizeof(version);
    if (!versionFn || versionFn(&version) != 0) return -1;
    sprintf_s(name->release, "%lu.%lu.%lu", version.dwMajorVersion, version.dwMinorVersion, version.dwBuildNumber);
    return 0;
}
inline int backtrace(void** addresses, int capacity) { return CaptureStackBackTrace(0, capacity, addresses, nullptr); }
inline char** backtrace_symbols(void* const* addresses, int count) {
    auto** result = static_cast<char**>(malloc(count * (sizeof(char*) + 32)));
    if (!result) return nullptr;
    auto* labels = reinterpret_cast<char*>(result + count);
    for (int i = 0; i < count; ++i) { result[i] = labels + i * 32; sprintf_s(result[i], 32, "%p", addresses[i]); }
    return result;
}
