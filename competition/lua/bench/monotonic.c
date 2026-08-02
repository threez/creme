/* A tiny Lua C extension exposing CLOCK_MONOTONIC — gives plain (non-JIT)
 * Lua the same sub-millisecond-resolution timer LuaJIT's own FFI-based
 * gettimeofday path already gets in bench.lua (see that file's own header
 * comment: os.clock()'s tick size is too coarse to register the fastest
 * workloads — tak(18,12,6)/string-build-test(4000) finish inside a single
 * tick on plain Lua here, reading back as an unmeasurable 0.0).
 *
 * luarocks' own luaposix (the standard way to get this in Lua) turned out
 * not to be installable against Lua 5.5 here: its rockspec unconditionally
 * depends on luabitop (a bitwise-ops shim only pre-5.3 Lua needs, since 5.3+
 * has native bitwise operators), which fails to compile against Lua 5.5's
 * luaconf.h ("Unknown number type, check LUA_NUMBER_* in luaconf.h" — it
 * hasn't been updated for Lua 5.5's very recent release). Not worth
 * patching an unrelated upstream C library just for a timer, hence this.
 *
 * Build once (see competition/bench.scm's own header comment, alongside
 * bin/bench_cr/bin/bench_go's own one-time build commands):
 *   cc -shared -fPIC $(pkg-config --cflags lua-5.5) -o competition/lua/bench/monotonic.so \
 *     competition/lua/bench/monotonic.c $(pkg-config --libs lua-5.5)
 * bench.lua adds competition/lua/bench/?.so to package.cpath itself and
 * falls back to os.clock() if this hasn't been built or fails to load, so
 * it's optional exactly like every other comparison variant in this harness. */
#include <time.h>

#include <lauxlib.h>
#include <lua.h>

static int l_now(lua_State *L) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  lua_pushnumber(L, (lua_Number)ts.tv_sec + (lua_Number)ts.tv_nsec / 1e9);
  return 1;
}

static const luaL_Reg funcs[] = {
    {"now", l_now},
    {NULL, NULL},
};

int luaopen_monotonic(lua_State *L) {
  luaL_newlib(L, funcs);
  return 1;
}
