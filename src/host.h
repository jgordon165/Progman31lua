// The Lua modules the C++ host provides: `mem` (the 16-bit machine's linear
// memory), `fb` (GDI surfaces), and `host` (files, window, input, time,
// launching programs).
#pragma once

#include <string>
#include <vector>

struct lua_State;

struct HostConfig {
    std::vector<std::string> args;   // everything after the program name
    bool headless = false;           // no window: SDL's dummy video driver (tests)
    double scale = 1.0;
};

void openHostLibs(lua_State* L, HostConfig* cfg);
void closeHost();
