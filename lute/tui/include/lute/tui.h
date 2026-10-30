#pragma once
#include "lute/library.h"

#include "lua.h"

LUTE_API int luteopen_tui(lua_State* L);
namespace tui
{
bool terminalOwned();
}
