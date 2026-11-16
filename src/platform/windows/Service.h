#pragma once
namespace olr_windows {
    int runServiceOrConsole(int argc, char** argv, int (*application)(int, char**), void (*stop)());
}
