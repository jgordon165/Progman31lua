cmake_minimum_required(VERSION 3.20)
project(Progman31lua VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(PROGMAN31LUA_TESTS "Build the test suite" ON)

# One static MSVC runtime for everything (SDL, Lua and the engine), so
# releases need no Visual C++ redistributable and nothing mismatches at link.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

include(FetchContent)

# ---- SDL2 (static) ---------------------------------------------------------
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON  CACHE BOOL "" FORCE)
set(SDL_TEST   OFF CACHE BOOL "" FORCE)
FetchContent_Declare(SDL2
    GIT_REPOSITORY https://github.com/libsdl-org/SDL.git
    GIT_TAG        release-2.30.9
    GIT_SHALLOW    TRUE)
FetchContent_MakeAvailable(SDL2)

# ---- Lua 5.4 (built from source; upstream has no CMake) ---------------------
FetchContent_Declare(lua
    GIT_REPOSITORY https://github.com/lua/lua.git
    GIT_TAG        v5.4.7
    GIT_SHALLOW    TRUE)
FetchContent_MakeAvailable(lua)

file(GLOB LUA_SOURCES ${lua_SOURCE_DIR}/*.c)
list(FILTER LUA_SOURCES EXCLUDE REGEX ".*/(lua|luac|onelua|ltests)\\.c$")
add_library(lua_static STATIC ${LUA_SOURCES})
target_include_directories(lua_static PUBLIC ${lua_SOURCE_DIR})
set_target_properties(lua_static PROPERTIES LINKER_LANGUAGE C)
target_compile_options(lua_static PRIVATE $<IF:$<C_COMPILER_ID:MSVC>,/W0,-w>)   # third-party code
if(UNIX AND NOT APPLE)
    target_compile_definitions(lua_static PRIVATE LUA_USE_LINUX)
    target_link_libraries(lua_static PUBLIC m dl)
elseif(APPLE)
    target_compile_definitions(lua_static PRIVATE LUA_USE_MACOSX)
endif()

# ---- Warnings ----------------------------------------------------------------
function(progman31lua_warnings target)
    if(MSVC)
        target_compile_options(${target} PRIVATE /W4 /permissive- /utf-8)
    else()
        target_compile_options(${target} PRIVATE -Wall -Wextra)
    endif()
endfunction()

# ---- File formats (no SDL; shared by the host and the tests) -----------------
# Setup-disk compression (SZDD/KWAJ), 16-bit Windows executables (NE),
# bitmaps (DIB, including the RLE startup logo) and raster fonts (.FNT).
add_library(progman31lua_formats STATIC
    src/formats/binreader.cpp
    src/formats/ne.cpp
    src/formats/dib.cpp
    src/formats/fnt.cpp
    src/formats/expand.cpp)
target_include_directories(progman31lua_formats PUBLIC src)
progman31lua_warnings(progman31lua_formats)

# ---- Host ------------------------------------------------------------------
add_executable(progman31lua
    src/main.cpp
    src/host.cpp
    src/fb.cpp)
target_link_libraries(progman31lua PRIVATE progman31lua_formats SDL2::SDL2-static SDL2::SDL2main lua_static)
progman31lua_warnings(progman31lua)
if(MSVC)
    target_compile_options(progman31lua PRIVATE $<$<CONFIG:Release>:/Zi>)
    target_link_options(progman31lua PRIVATE $<$<CONFIG:Release>:/DEBUG /OPT:REF /OPT:ICF>)
    set_target_properties(progman31lua PROPERTIES WIN32_EXECUTABLE TRUE)
endif()
if(WIN32)
    target_link_libraries(progman31lua PRIVATE shell32)
endif()

# Copy Lua scripts next to the binary on every build, so script edits are
# picked up by a plain rebuild.
add_custom_target(copy_scripts ALL
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${CMAKE_SOURCE_DIR}/scripts $<TARGET_FILE_DIR:progman31lua>/scripts
    COMMENT "Copying Lua scripts")
add_dependencies(copy_scripts progman31lua)

# ---- Tests -------------------------------------------------------------------
# No Windows files are in the repository, so CI runs the data-free tests:
# the x86 recompiler against hand-assembled code, the file formats, and a
# headless boot without PROGMAN.EXE. Set PROGMAN31LUA_DATA=<folder with
# PROGMAN.EXE, or a Windows 3.1 setup disk> to also run Program Manager itself.
if(PROGMAN31LUA_TESTS)
    enable_testing()
    add_executable(progman31lua_tests tests/test_formats.cpp)
    target_link_libraries(progman31lua_tests PRIVATE progman31lua_formats)
    progman31lua_warnings(progman31lua_tests)
    add_test(NAME formats COMMAND progman31lua_tests)

    add_test(NAME recomp COMMAND progman31lua --headless --scripts ${CMAKE_SOURCE_DIR}/scripts
             --test ${CMAKE_SOURCE_DIR}/tests/lua/test_recomp.lua)
    add_test(NAME png COMMAND progman31lua --headless --scripts ${CMAKE_SOURCE_DIR}/scripts
             --test ${CMAKE_SOURCE_DIR}/tests/lua/test_png.lua)
    add_test(NAME boot COMMAND progman31lua --headless --scripts ${CMAKE_SOURCE_DIR}/scripts
             --data ${CMAKE_BINARY_DIR}/no-such-folder --exit-after 1500)
    if(DEFINED ENV{PROGMAN31LUA_DATA})
        set_tests_properties(formats PROPERTIES ENVIRONMENT "PROGMAN31LUA_DATA=$ENV{PROGMAN31LUA_DATA}")
        add_test(NAME progman COMMAND progman31lua --headless --scripts ${CMAKE_SOURCE_DIR}/scripts
                 --data $ENV{PROGMAN31LUA_DATA} --home ${CMAKE_BINARY_DIR}/test-home --fresh
                 --test ${CMAKE_SOURCE_DIR}/tests/lua/test_progman.lua)
        # Control Panel: the original CONTROL.EXE and its applets as a second task
        add_test(NAME control COMMAND progman31lua --headless --scripts ${CMAKE_SOURCE_DIR}/scripts
                 --data $ENV{PROGMAN31LUA_DATA} --home ${CMAKE_BINARY_DIR}/test-control-home --fresh
                 --test ${CMAKE_SOURCE_DIR}/tests/lua/test_control.lua)
        # the Games group from a games folder: two Program Manager runs per home
        foreach(phase setup sync plain upgrade)
            if(phase STREQUAL "setup" OR phase STREQUAL "sync")
                set(home ${CMAKE_BINARY_DIR}/test-games-1)
            else()
                set(home ${CMAKE_BINARY_DIR}/test-games-2)
            endif()
            set(fresh "")
            if(phase STREQUAL "setup" OR phase STREQUAL "plain")
                set(fresh --fresh)
            endif()
            add_test(NAME games-${phase} COMMAND progman31lua --headless --scripts ${CMAKE_SOURCE_DIR}/scripts
                     --data $ENV{PROGMAN31LUA_DATA} --home ${home} ${fresh} --phase ${phase}
                     --test ${CMAKE_SOURCE_DIR}/tests/lua/test_games.lua)
        endforeach()
        set_tests_properties(games-sync PROPERTIES DEPENDS games-setup)
        set_tests_properties(games-upgrade PROPERTIES DEPENDS games-plain)
    endif()
endif()

# ---- Install (packages) --------------------------------------------------------
install(TARGETS progman31lua RUNTIME DESTINATION . COMPONENT game)
install(DIRECTORY scripts DESTINATION . COMPONENT game)
install(FILES README.md DESTINATION . COMPONENT game)
install(FILES games/README.txt DESTINATION games COMPONENT game)
