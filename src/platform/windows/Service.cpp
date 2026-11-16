// Native Windows product lifecycle. GPL-3.0-or-later.
#include "Service.h"
#include <filesystem>
#include <fstream>
#include <streambuf>
#include <iostream>
#include <vector>
#include <atomic>
#include <algorithm>

namespace olr_windows {
namespace {
    struct Options {
        bool service{false};
        std::wstring name{L"OpenLogReplicator"};
        std::wstring oracleHome;
        uint64_t logMaxBytes{10 * 1024 * 1024};
        unsigned logKeep{5};
        std::vector<std::string> arguments;
    } options;
    SERVICE_STATUS_HANDLE statusHandle{};
    SERVICE_STATUS status{};
    std::mutex statusMutex;
    std::atomic<bool> stopping{false};
    int (*runApplication)(int, char**){};
    void (*stopApplication)(){};

    class RotatingLog final : public std::streambuf {
        std::filesystem::path path;
        std::ofstream file;
        uint64_t size{};
        std::mutex mutex;
        std::atomic<bool> broken{false};
        bool rotate() {
            file.close();
            std::error_code error;
            auto archive = [&](unsigned n) { return std::filesystem::path(path.wstring() + L"." + std::to_wstring(n)); };
            std::filesystem::remove(archive(options.logKeep), error);
            if (error) return false;
            for (unsigned i = options.logKeep; i > 1; --i) {
                if (std::filesystem::exists(archive(i - 1), error)) {
                    std::filesystem::rename(archive(i - 1), archive(i), error);
                    if (error) return false;
                }
            }
            std::filesystem::rename(path, archive(1), error);
            if (error) return false;
            file.open(path, std::ios::binary | std::ios::trunc);
            size = 0;
            return file.is_open();
        }
    protected:
        std::streamsize xsputn(const char* data, std::streamsize length) override {
            std::lock_guard<std::mutex> lock(mutex);
            if (broken || length < 0) return 0;
            if (size && size + static_cast<uint64_t>(length) > options.logMaxBytes && !rotate()) {
                broken = true; return 0;
            }
            file.write(data, length);
            file.flush();
            if (!file) { broken = true; return 0; }
            size += static_cast<uint64_t>(length);
            return length;
        }
        int overflow(int character) override {
            if (character == traits_type::eof()) return traits_type::not_eof(character);
            const char value = static_cast<char>(character);
            return xsputn(&value, 1) == 1 ? character : traits_type::eof();
        }
        int sync() override {
            std::lock_guard<std::mutex> lock(mutex);
            file.flush();
            if (!file) broken = true;
            return broken ? -1 : 0;
        }
    public:
        explicit RotatingLog(const std::filesystem::path& directory) : path(directory / L"OpenLogReplicator.log") {
            std::filesystem::create_directories(directory);
            if (std::filesystem::exists(path)) size = std::filesystem::file_size(path);
            file.open(path, std::ios::binary | std::ios::app);
            if (!file.is_open()) throw std::runtime_error("cannot open service diagnostic log");
        }
        bool failed() const { return broken; }
    };

    void report(DWORD state, DWORD result = 0) {
        std::lock_guard<std::mutex> lock(statusMutex);
        status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        status.dwCurrentState = state;
        status.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN | SERVICE_ACCEPT_PRESHUTDOWN : 0;
        status.dwWin32ExitCode = result ? ERROR_SERVICE_SPECIFIC_ERROR : ERROR_SUCCESS;
        status.dwServiceSpecificExitCode = result;
        status.dwWaitHint = state == SERVICE_STOP_PENDING || state == SERVICE_START_PENDING ? 30000 : 0;
        status.dwCheckPoint = status.dwWaitHint ? status.dwCheckPoint + 1 : 0;
        SetServiceStatus(statusHandle, &status);
    }
    void requestStop() {
        if (!stopping.exchange(true)) {
            if (statusHandle) report(SERVICE_STOP_PENDING);
            stopApplication();
        }
    }
    DWORD WINAPI control(DWORD command, DWORD, void*, void*) {
        if (command == SERVICE_CONTROL_STOP || command == SERVICE_CONTROL_SHUTDOWN || command == SERVICE_CONTROL_PRESHUTDOWN) {
            requestStop(); return ERROR_SUCCESS;
        }
        if (command == SERVICE_CONTROL_INTERROGATE) {
            std::lock_guard<std::mutex> lock(statusMutex);
            SetServiceStatus(statusHandle, &status); return ERROR_SUCCESS;
        }
        return ERROR_CALL_NOT_IMPLEMENTED;
    }
    BOOL WINAPI consoleControl(DWORD command) {
        if (command == CTRL_C_EVENT || command == CTRL_BREAK_EVENT || command == CTRL_CLOSE_EVENT || command == CTRL_SHUTDOWN_EVENT) {
            requestStop(); return true;
        }
        return false;
    }
    void configureOracle() {
        if (options.oracleHome.empty()) return; // Console can use an existing OCI PATH.
        std::filesystem::path home(options.oracleHome);
        auto bin = std::filesystem::exists(home / L"bin" / L"oci.dll") ? home / L"bin" : home;
        if (!std::filesystem::exists(bin / L"oci.dll")) throw std::runtime_error("Oracle home has no oci.dll");
        if (!SetDllDirectoryW(bin.c_str())) throw std::runtime_error("cannot configure Oracle DLL directory");
        std::wstring path;
        const DWORD count = GetEnvironmentVariableW(L"PATH", nullptr, 0);
        if (count) { path.resize(count); GetEnvironmentVariableW(L"PATH", path.data(), count); path.resize(count - 1); }
        path = bin.wstring() + L";" + path;
        if (!SetEnvironmentVariableW(L"PATH", path.c_str())) throw std::runtime_error("cannot configure Oracle PATH");
        if (bin != home) SetEnvironmentVariableW(L"ORACLE_HOME", home.c_str());
        if (!LoadLibraryExW((bin / L"oci.dll").c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH))
            throw std::runtime_error("cannot load Oracle OCI runtime, Windows error " + std::to_string(GetLastError()));
    }
    int invokeApplication() {
        configureOracle();
        std::vector<char*> argv;
        for (auto& argument : options.arguments) argv.push_back(argument.data());
        argv.push_back(nullptr);
        return runApplication(static_cast<int>(argv.size() - 1), argv.data());
    }
    void WINAPI serviceMain(DWORD, wchar_t**) {
        statusHandle = RegisterServiceCtrlHandlerExW(options.name.c_str(), control, nullptr);
        if (!statusHandle) return;
        report(SERVICE_START_PENDING);
        try {
            wchar_t executable[32768];
            const DWORD count = GetModuleFileNameW(nullptr, executable, 32768);
            if (!count || count >= 32768) throw std::runtime_error("cannot locate executable");
            const auto root = std::filesystem::path(executable).parent_path().parent_path();
            if (!SetCurrentDirectoryW(root.c_str())) throw std::runtime_error("cannot select product directory");
            RotatingLog logger(root / L"logs");
            auto* originalError = std::cerr.rdbuf(&logger);
            auto* originalOutput = std::cout.rdbuf(&logger);
            std::cerr << "Windows service starting\n";
            std::atomic<bool> done{false};
            int result = 1;
            try {
                std::thread application([&] {
                    try { result = invokeApplication(); }
                    catch (const std::exception& error) { std::cerr << "Windows startup failure: " << error.what() << '\n'; result = 1; }
                    catch (...) { std::cerr << "Windows startup failure\n"; result = 1; }
                    done = true;
                });
                report(SERVICE_RUNNING);
                while (!done) {
                    if (logger.failed()) requestStop();
                    if (stopping) report(SERVICE_STOP_PENDING);
                    Sleep(250);
                }
                application.join();
            } catch (const std::exception& error) {
                std::cerr << "Windows lifecycle failure: " << error.what() << '\n';
                result = 1;
            }
            if (logger.failed()) result = 1;
            std::cerr << "Windows service stopped, exit code " << result << '\n';
            std::cerr.rdbuf(originalError);
            std::cout.rdbuf(originalOutput);
            report(SERVICE_STOPPED, static_cast<DWORD>(result));
        } catch (...) {
            report(SERVICE_STOPPED, 1);
        }
    }
}

int runServiceOrConsole(int argc, char** argv, int (*application)(int, char**), void (*stop)()) {
    runApplication = application;
    stopApplication = stop;
    options.arguments.emplace_back(argv[0]);
    try {
        for (int i = 1; i < argc; ++i) {
            const std::string argument(argv[i]);
            auto value = [&]() -> std::string {
                if (++i >= argc) throw std::runtime_error("missing value for " + argument);
                return argv[i];
            };
            if (argument == "--service") options.service = true;
            else if (argument == "--service-name") options.name = wide(value().c_str());
            else if (argument == "--oracle-home") options.oracleHome = wide(value().c_str());
            else if (argument == "--log-max-bytes") options.logMaxBytes = std::stoull(value());
            else if (argument == "--log-keep") options.logKeep = static_cast<unsigned>(std::stoul(value()));
            else options.arguments.push_back(argument);
        }
        if (options.name.empty() || options.logMaxBytes < 1024 || options.logKeep < 1 || options.logKeep > 100)
            throw std::runtime_error("invalid Windows service/log options");
        if (options.service) {
            if (options.oracleHome.empty()) throw std::runtime_error("--service requires --oracle-home");
            SERVICE_TABLE_ENTRYW entries[] = {{options.name.data(), serviceMain}, {nullptr, nullptr}};
            if (!StartServiceCtrlDispatcherW(entries)) {
                std::cerr << "Cannot connect to Windows SCM, error " << GetLastError() << '\n'; return 1;
            }
            return 0;
        }
        SetConsoleCtrlHandler(consoleControl, true);
        const int result = invokeApplication();
        SetConsoleCtrlHandler(consoleControl, false);
        return result;
    } catch (const std::exception& error) {
        std::cerr << "Windows startup failure: " << error.what() << '\n'; return 1;
    }
}
}
