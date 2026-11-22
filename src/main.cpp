// Progman31lua: runs Windows 3.1's Program Manager (PROGMAN.EXE, 1992) as a
// modern program. The 16-bit x86 code is recompiled to Lua at runtime
// (scripts/recomp/) and its calls into Windows are served by a Win16 layer
// written in Lua (scripts/win16/). This host provides memory, drawing,
// input, files and a Lua 5.4 VM. Nothing from Windows 3.1 is compiled in or
// shipped: PROGMAN.EXE and the rest are read from the user's own copy.
//
// Usage: progman31lua [--data <Windows 3.1 folder or setup disk>] [--scale N]
//                     [--scripts <dir>] [--headless] [other options read by scripts/main.lua]

#include "host.h"

extern "C" {
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"
}

#include <SDL.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>

namespace fs = std::filesystem;

static int traceback(lua_State* L) {
    luaL_traceback(L, L, lua_tostring(L, 1), 1);
    return 1;
}

int main(int argc, char** argv) {
    HostConfig cfg;
    std::string scripts;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--headless") cfg.headless = true;
        else if (a == "--scripts" && i + 1 < argc) { scripts = argv[i + 1]; }
        else if (a == "--scale" && i + 1 < argc) { cfg.scale = std::atof(argv[i + 1]); }
        cfg.args.push_back(a);
    }
    if (const char* env = std::getenv("PROGMAN31LUA_SCRIPTS"); scripts.empty() && env) scripts = env;
    if (cfg.headless) {
        SDL_setenv("SDL_VIDEODRIVER", "dummy", 1);
        SDL_setenv("SDL_AUDIODRIVER", "dummy", 1);
    }
#ifdef _WIN32
    // The window's icon: the executable's own (src/progman31lua.rc).
    SDL_SetHint(SDL_HINT_WINDOWS_INTRESOURCE_ICON, "1");
    SDL_SetHint(SDL_HINT_WINDOWS_INTRESOURCE_ICON_SMALL, "1");
#endif
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_TIMER) != 0) {
        std::fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    if (scripts.empty()) {
        char* base = SDL_GetBasePath();
        scripts = std::string(base ? base : "./") + "scripts";
        SDL_free(base);
    }

    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    openHostLibs(L, &cfg);
    // require() finds the scripts folder.
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "path");
    const std::string path = scripts + "/?.lua;" + scripts + "/?/init.lua;" + lua_tostring(L, -1);
    lua_pop(L, 1);
    lua_pushstring(L, path.c_str());
    lua_setfield(L, -2, "path");
    lua_pop(L, 1);
    lua_pushstring(L, scripts.c_str());
    lua_setglobal(L, "SCRIPTS");

    int rc = 0;
    lua_pushcfunction(L, traceback);
    const std::string mainLua = scripts + "/main.lua";
    if (luaL_loadfile(L, mainLua.c_str()) != LUA_OK || lua_pcall(L, 0, 1, -2) != LUA_OK) {
        const std::string msg = lua_tostring(L, -1) ? lua_tostring(L, -1) : "error";
        std::fprintf(stderr, "%s\n", msg.c_str());
        if (!cfg.headless)
            SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "Progman31lua",
                                     (msg + "\n\nPlease report this at https://github.com/jgordon165/Progman31lua/issues").c_str(),
                                     nullptr);
        rc = 1;
    } else if (lua_isinteger(L, -1)) {
        rc = static_cast<int>(lua_tointeger(L, -1));
    }
    lua_close(L);
    closeHost();
    SDL_Quit();
    return rc;
}
