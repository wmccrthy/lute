#include "lute/tui.h"

#include "lute/runtime.h"
#include "lute/tuicore.h"

#include "lualib.h"

#include "uv.h"

#include <algorithm>
#include <atomic>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>

namespace tui
{
namespace
{
constexpr const char* metatable = "lute.tui.session";
constexpr const char* restore = "\x1b[0m\x1b[?1000l\x1b[?1002l\x1b[?1006l\x1b[?2004l\x1b[?25h\x1b[?1049l";
std::atomic<bool> owned{false};
std::once_flag exitHook;

void emergencyRestore()
{
    if (!owned.load())
        return;
    uv_tty_reset_mode();
    std::fwrite(restore, 1, std::strlen(restore), stdout);
    std::fflush(stdout);
}

int pushEvent(lua_State* L, const Event& e)
{
    lua_createtable(L, 0, 12);
    auto str = [&](const char* field, const std::string& value)
    {
        lua_pushlstring(L, value.data(), value.size());
        lua_setfield(L, -2, field);
    };
    auto num = [&](const char* field, int value)
    {
        lua_pushinteger(L, value);
        lua_setfield(L, -2, field);
    };
    auto flag = [&](const char* field, bool value)
    {
        lua_pushboolean(L, value);
        lua_setfield(L, -2, field);
    };
    str("kind", e.kind);
    if (e.kind == "key")
    {
        str("key", e.key);
        str("text", e.text);
    }
    if (e.kind == "paste")
        str("text", e.text);
    if (e.kind == "resize")
    {
        num("width", e.x);
        num("height", e.y);
    }
    if (e.kind == "mouse")
    {
        num("x", e.x);
        num("y", e.y);
        num("button", e.button);
        str("action", e.action);
    }
    if (e.kind == "key" || e.kind == "mouse")
    {
        flag("ctrl", e.ctrl);
        flag("alt", e.alt);
        flag("shift", e.shift);
    }
    return 1;
}

struct Session : std::enable_shared_from_this<Session>
{
    uv_tty_t* input = nullptr;
    uv_tty_t* output = nullptr;
    uv_timer_t* timer = nullptr;
    uv_signal_t* interrupt = nullptr;
    uv_signal_t* terminate = nullptr;
#ifndef _WIN32
    uv_signal_t* hangup = nullptr;
#endif
    std::shared_ptr<Session> self;
    Screen screen{1, 1};
    Input decoder;
    ResumeToken reader;
    bool closed = false, raw = false, entered = false, presenting = false;
    bool mouse = false;
    int closing = 0;
    uint64_t escapeSince = 0;
    int escapeDelay = 30;
    std::string failure;
    char readBuffer[1024];

    ~Session()
    {
        close();
    }

    template<typename T>
    void closeHandle(T*& pointer)
    {
        if (!pointer)
            return;
        ++closing;
        uv_close(
            reinterpret_cast<uv_handle_t*>(pointer),
            [](uv_handle_t* handle)
            {
                auto* s = static_cast<Session*>(handle->data);
                // uv handles have different allocation sizes; use their actual type.
                if (handle->type == UV_TTY)
                    delete reinterpret_cast<uv_tty_t*>(handle);
                else if (handle->type == UV_TIMER)
                    delete reinterpret_cast<uv_timer_t*>(handle);
                else
                    delete reinterpret_cast<uv_signal_t*>(handle);
                if (--s->closing == 0)
                    s->self.reset();
            }
        );
        pointer = nullptr;
    }

    void close(const std::string& reason = "tui session is closed")
    {
        if (closed)
            return;
        closed = true;
        failure = reason;
        if (input)
            uv_read_stop(reinterpret_cast<uv_stream_t*>(input));
        if (timer)
            uv_timer_stop(timer);
        if (raw && input)
            uv_tty_set_mode(input, UV_TTY_MODE_NORMAL);
        // Closing the output first prevents any queued frame from being written
        // after the synchronous restoration sequence below.
        closeHandle(output);
        if (entered)
        {
            uv_fs_t request;
            uv_buf_t buffer = uv_buf_init(const_cast<char*>(restore), unsigned(std::strlen(restore)));
            uv_fs_write(nullptr, &request, fileno(stdout), &buffer, 1, -1, nullptr);
            uv_fs_req_cleanup(&request);
        }
        closeHandle(input);
        closeHandle(timer);
        closeHandle(interrupt);
        closeHandle(terminate);
#ifndef _WIN32
        closeHandle(hangup);
#endif
        owned.store(false);
        if (reader)
        {
            auto token = std::move(reader);
            token->fail(reason);
        }
        if (!closing)
            self.reset();
    }

    void deliver()
    {
        if (!reader || decoder.events.empty())
            return;
        auto event = std::move(decoder.events.front());
        decoder.events.pop_front();
        auto token = std::move(reader);
        uv_read_stop(reinterpret_cast<uv_stream_t*>(input));
        uv_unref(reinterpret_cast<uv_handle_t*>(input));
        token->complete(
            [event = std::move(event)](lua_State* L)
            {
                return pushEvent(L, event);
            }
        );
    }

    int initialize(uv_loop_t* loop)
    {
        self = shared_from_this();
        auto initTty = [&](uv_tty_t*& pointer, int fd)
        {
            auto handle = std::make_unique<uv_tty_t>();
            int status = uv_tty_init(loop, handle.get(), fd, 0);
            if (status < 0)
                return status;
            pointer = handle.release();
            pointer->data = this;
            uv_unref(reinterpret_cast<uv_handle_t*>(pointer));
            return 0;
        };
        int status = initTty(input, fileno(stdin));
        if (status < 0)
            return status;
        status = initTty(output, fileno(stdout));
        if (status < 0)
            return status;
        status = uv_tty_set_mode(input, UV_TTY_MODE_RAW_VT);
        if (status < 0)
            return status;
        raw = true;
        int width, height;
        status = uv_tty_get_winsize(output, &width, &height);
        if (status < 0)
            return status;
        screen.resize(std::max(1, width), std::max(1, height));
        auto handle = std::make_unique<uv_timer_t>();
        status = uv_timer_init(loop, handle.get());
        if (status < 0)
            return status;
        timer = handle.release();
        timer->data = this;
        uv_unref(reinterpret_cast<uv_handle_t*>(timer));
        auto watchSignal = [&](uv_signal_t*& pointer, int number)
        {
            auto signal = std::make_unique<uv_signal_t>();
            int status = uv_signal_init(loop, signal.get());
            if (status < 0)
                return status;
            pointer = signal.release();
            pointer->data = this;
            uv_unref(reinterpret_cast<uv_handle_t*>(pointer));
            return uv_signal_start(
                pointer,
                [](uv_signal_t* handle, int signum)
                {
                    auto* s = static_cast<Session*>(handle->data);
                    s->close("tui interrupted");
                    std::signal(signum, SIG_DFL);
                    std::raise(signum);
                },
                number
            );
        };
        status = watchSignal(interrupt, SIGINT);
        if (status < 0)
            return status;
        status = watchSignal(terminate, SIGTERM);
        if (status < 0)
            return status;
#ifndef _WIN32
        status = watchSignal(hangup, SIGHUP);
        if (status < 0)
            return status;
#endif
        return uv_timer_start(
            timer,
            [](uv_timer_t* handle)
            {
                auto* s = static_cast<Session*>(handle->data);
                try
                {
                    int width, height;
                    int status = uv_tty_get_winsize(s->output, &width, &height);
                    if (status < 0)
                    {
                        s->close(uv_strerror(status));
                        return;
                    }
                    // Some terminals report zero dimensions while minimized.
                    // Keep a valid logical viewport instead of closing the session.
                    width = std::max(1, width);
                    height = std::max(1, height);
                    if (width != s->screen.width() || height != s->screen.height())
                    {
                        s->screen.resize(width, height);
                        Event e;
                        e.kind = "resize";
                        e.x = width;
                        e.y = height;
                        // Coalesce resize bursts without displacing key/paste events.
                        if (!s->decoder.events.empty() && s->decoder.events.back().kind == "resize")
                            s->decoder.events.back() = std::move(e);
                        else if (s->decoder.events.size() < Input::maxEvents)
                            s->decoder.events.push_back(std::move(e));
                    }
                    if (s->decoder.waitingEscape())
                    {
                        uint64_t now = uv_now(handle->loop);
                        if (!s->escapeSince)
                            s->escapeSince = now;
                        if (now - s->escapeSince >= uint64_t(s->escapeDelay))
                        {
                            s->decoder.expireEscape();
                            s->escapeSince = 0;
                        }
                    }
                    else
                        s->escapeSince = 0;
                    s->deliver();
                }
                catch (const std::exception& e)
                {
                    s->close(e.what());
                }
            },
            10,
            10
        );
    }
};

using SessionPtr = std::shared_ptr<Session>;
Session& check(lua_State* L, bool allowClosed = false)
{
    auto* storage = static_cast<SessionPtr*>(luaL_checkudata(L, 1, metatable));
    if (!allowClosed && (*storage)->closed)
        luaL_error(L, "%s", (*storage)->failure.c_str());
    return **storage;
}

struct Write
{
    uv_write_t request{};
    SessionPtr session;
    ResumeToken token;
    std::string bytes;
};

int writeFrame(lua_State* L, Session& session, std::string bytes)
{
    if (bytes.empty())
        return 0;
    auto write = std::make_unique<Write>();
    write->session = session.shared_from_this();
    write->bytes = std::move(bytes);
    write->request.data = write.get();
    uv_buf_t buffer = uv_buf_init(write->bytes.data(), unsigned(write->bytes.size()));
    // The token is created only once uv_write successfully accepts the request.
    int status = uv_write(
        &write->request,
        reinterpret_cast<uv_stream_t*>(session.output),
        &buffer,
        1,
        [](uv_write_t* request, int status)
        {
            std::unique_ptr<Write> write(static_cast<Write*>(request->data));
            write->session->presenting = false;
            if (status < 0)
            {
                write->session->close(uv_strerror(status));
                write->token->fail(uv_strerror(status));
            }
            else
                write->token->complete(
                    [](lua_State*)
                    {
                        return 0;
                    }
                );
        }
    );
    if (status < 0)
    {
        session.close(uv_strerror(status));
        luaL_error(L, "tui write: %s", uv_strerror(status));
    }
    session.presenting = true;
    write->token = getResumeToken(L);
    write.release();
    return lua_yield(L, 0);
}

bool option(lua_State* L, int index, const char* name, bool fallback)
{
    if (lua_isnoneornil(L, index))
        return fallback;
    lua_getfield(L, index, name);
    if (!lua_isnil(L, -1))
        luaL_checktype(L, -1, LUA_TBOOLEAN);
    bool result = lua_isnil(L, -1) ? fallback : lua_toboolean(L, -1);
    lua_pop(L, 1);
    return result;
}

int open(lua_State* L)
{
    if (!lua_isnoneornil(L, 1))
        luaL_checktype(L, 1, LUA_TTABLE);
    bool mouse = option(L, 1, "mouse", false);
    int escapeDelay = 30;
    if (lua_istable(L, 1))
    {
        lua_getfield(L, 1, "escapedelay");
        if (!lua_isnil(L, -1))
            escapeDelay = luaL_checkinteger(L, -1);
        lua_pop(L, 1);
    }
    luaL_argcheck(L, escapeDelay >= 1 && escapeDelay <= 1000, 1, "escapedelay must be 1..1000 milliseconds");
    if (uv_guess_handle(fileno(stdin)) != UV_TTY || uv_guess_handle(fileno(stdout)) != UV_TTY)
        luaL_error(L, "tui requires terminal stdin and stdout");
    const char* term = std::getenv("TERM");
    if (term && std::strcmp(term, "dumb") == 0)
        luaL_error(L, "tui requires a VT-compatible terminal (TERM=dumb)");

    // Allocate userdata before reserving the terminal, so a VM allocation error
    // cannot strand the process-wide ownership flag.
    auto* storage = static_cast<SessionPtr*>(lua_newuserdatadtor(
        L,
        sizeof(SessionPtr),
        [](lua_State*, void* ptr)
        {
            auto* session = static_cast<SessionPtr*>(ptr);
            if (*session)
                (*session)->close();
            session->~SessionPtr();
        }
    ));
    new (storage) SessionPtr();
    luaL_getmetatable(L, metatable);
    lua_setmetatable(L, -2);
    bool expected = false;
    if (!owned.compare_exchange_strong(expected, true))
        luaL_error(L, "terminal is already owned by a tui session");
    try
    {
        *storage = std::make_shared<Session>();
        auto& s = **storage;
        s.mouse = mouse;
        s.escapeDelay = escapeDelay;
        int status = s.initialize(getRuntimeLoop(L));
        if (status < 0)
        {
            s.close();
            luaL_error(L, "tui open: %s", uv_strerror(status));
        }
        std::weak_ptr<Session> weak = *storage;
        // Keep the key allocated until runtime shutdown so a later session
        // cannot reuse its address and silently lose its shutdown hook.
        auto hookKey = std::make_shared<char>();
        getRuntime(L)->addShutdownHook(
            hookKey.get(),
            [weak, hookKey]()
            {
                if (auto s = weak.lock())
                    s->close();
            }
        );
        std::call_once(
            exitHook,
            []
            {
                std::atexit(emergencyRestore);
            }
        );
        std::string enter = "\x1b[?1049h\x1b[?25l\x1b[?2004h\x1b[0m";
        if (mouse)
            enter += "\x1b[?1002h\x1b[?1006h";
        // Opening returns the session synchronously; mode setup is a short,
        // checked synchronous write. Frames use asynchronous uv_write instead.
        uv_fs_t request;
        uv_buf_t buffer = uv_buf_init(enter.data(), unsigned(enter.size()));
        s.entered = true;
        auto written = uv_fs_write(nullptr, &request, fileno(stdout), &buffer, 1, -1, nullptr);
        uv_fs_req_cleanup(&request);
        if (written != int64_t(enter.size()))
        {
            s.close();
            luaL_error(L, "tui failed to enter alternate screen");
        }
    }
    catch (const std::exception& e)
    {
        if (*storage)
            (*storage)->close();
        else
            owned.store(false);
        luaL_error(L, "tui open: %s", e.what());
    }
    return 1;
}

int read(lua_State* L)
{
    auto& s = check(L);
    if (s.reader)
        luaL_error(L, "tui session already has a pending read");
    if (!s.decoder.events.empty())
    {
        auto event = std::move(s.decoder.events.front());
        s.decoder.events.pop_front();
        return pushEvent(L, event);
    }
    int status = uv_read_start(
        reinterpret_cast<uv_stream_t*>(s.input),
        [](uv_handle_t* handle, size_t, uv_buf_t* buffer)
        {
            auto* s = static_cast<Session*>(handle->data);
            *buffer = uv_buf_init(s->readBuffer, sizeof(s->readBuffer));
        },
        [](uv_stream_t* stream, ssize_t count, const uv_buf_t* buffer)
        {
            auto* s = static_cast<Session*>(stream->data);
            if (count < 0)
            {
                s->close(uv_strerror(int(count)));
                return;
            }
            if (!count)
                return;
            try
            {
                s->decoder.feed(std::string_view(buffer->base, size_t(count)));
                if (s->decoder.waitingEscape())
                    s->escapeSince = uv_now(stream->loop);
                s->deliver();
            }
            catch (const std::exception& e)
            {
                s->close(e.what());
            }
        }
    );
    if (status < 0)
    {
        s.close(uv_strerror(status));
        luaL_error(L, "tui read: %s", uv_strerror(status));
    }
    uv_ref(reinterpret_cast<uv_handle_t*>(s.input));
    s.reader = getResumeToken(L);
    return lua_yield(L, 0);
}

int close(lua_State* L)
{
    check(L, true).close();
    return 0;
}
int clear(lua_State* L)
{
    check(L).screen.clear();
    return 0;
}
int size(lua_State* L)
{
    auto& s = check(L);
    lua_pushinteger(L, s.screen.width());
    lua_pushinteger(L, s.screen.height());
    return 2;
}
int present(lua_State* L)
{
    auto& s = check(L);
    if (s.presenting)
        luaL_error(L, "tui session already has a pending present");
    return writeFrame(L, s, s.screen.render());
}
int color(lua_State* L, int index, const char* field)
{
    lua_getfield(L, index, field);
    int value = -1;
    if (lua_type(L, -1) == LUA_TNUMBER)
    {
        double number = lua_tonumber(L, -1);
        if (!(number >= 0 && number <= 255 && number == int(number)))
            luaL_error(L, "tui color index must be an integer in 0..255");
        value = int(number);
    }
    else if (lua_type(L, -1) == LUA_TSTRING)
    {
        size_t length;
        const char* text = lua_tolstring(L, -1, &length);
        if (length != 7 || text[0] != '#')
            luaL_error(L, "tui RGB color must be #rrggbb");
        value = 0;
        for (size_t i = 1; i < length; ++i)
        {
            char c = text[i];
            int digit = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
            if (digit < 0)
                luaL_error(L, "tui RGB color must be #rrggbb");
            value = (value << 4) | digit;
        }
        value |= 0x1000000;
    }
    else if (!lua_isnil(L, -1))
        luaL_error(L, "tui color must be an index or #rrggbb");
    lua_pop(L, 1);
    return value;
}
Style readStyle(lua_State* L, int index)
{
    Style style;
    if (!lua_isnoneornil(L, index))
    {
        luaL_checktype(L, index, LUA_TTABLE);
        style.fg = color(L, index, "fg");
        style.bg = color(L, index, "bg");
        style.bold = option(L, index, "bold", false);
        style.dim = option(L, index, "dim", false);
        style.italic = option(L, index, "italic", false);
        style.underline = option(L, index, "underline", false);
        style.reverse = option(L, index, "reverse", false);
    }
    return style;
}
int coordinate(lua_State* L, int index)
{
    int value = luaL_checkinteger(L, index);
    luaL_argcheck(L, value >= -4096 && value <= 4096, index, "coordinate out of range");
    return value;
}
int text(lua_State* L)
{
    auto& s = check(L);
    int x = coordinate(L, 2), y = coordinate(L, 3);
    size_t length;
    const char* value = luaL_checklstring(L, 4, &length);
    s.screen.text(x, y, std::string_view(value, length), readStyle(L, 5));
    return 0;
}
int fill(lua_State* L)
{
    auto& s = check(L);
    int x = coordinate(L, 2), y = coordinate(L, 3);
    int width = coordinate(L, 4), height = coordinate(L, 5);
    luaL_argcheck(L, width >= 0 && height >= 0, 4, "fill dimensions must be nonnegative");
    s.screen.fill(x, y, width, height, readStyle(L, 6));
    return 0;
}
int measureText(lua_State* L)
{
    size_t length;
    const char* value = luaL_checklstring(L, 1, &length);
    auto size = measure(std::string_view(value, length));
    lua_pushinteger(L, size.first);
    lua_pushinteger(L, size.second);
    return 2;
}
int clipText(lua_State* L)
{
    size_t length;
    const char* value = luaL_checklstring(L, 1, &length);
    int width = luaL_checkinteger(L, 2), offset = luaL_optinteger(L, 3, 0);
    luaL_argcheck(L, width >= 0 && width <= 4096, 2, "clip width must be 0..4096");
    luaL_argcheck(L, offset >= 0 && offset <= 1024 * 1024, 3, "clip offset must be 0..1048576");
    auto result = clip(std::string_view(value, length), width, offset);
    lua_pushlstring(L, result.data(), result.size());
    return 1;
}
int supported(lua_State* L)
{
    const char* term = std::getenv("TERM");
    lua_pushboolean(
        L, uv_guess_handle(fileno(stdin)) == UV_TTY && uv_guess_handle(fileno(stdout)) == UV_TTY && (!term || std::strcmp(term, "dumb") != 0)
    );
    return 1;
}
} // namespace

bool terminalOwned()
{
    return owned.load();
}
} // namespace tui

int luteopen_tui(lua_State* L)
{
    luaL_newmetatable(L, tui::metatable);
    lua_newtable(L);
    const luaL_Reg methods[] = {
        {"read", tui::read},
        {"close", tui::close},
        {"clear", tui::clear},
        {"size", tui::size},
        {"text", tui::text},
        {"fill", tui::fill},
        {"present", tui::present},
        {nullptr, nullptr}
    };
    for (auto* method = methods; method->name; ++method)
    {
        lua_pushcfunction(L, method->func, method->name);
        lua_setfield(L, -2, method->name);
    }
    lua_setreadonly(L, -1, 1);
    lua_setfield(L, -2, "__index");
    lua_pushstring(L, "tui session");
    lua_setfield(L, -2, "__metatable");
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushcfunction(L, tui::open, "tui.open");
    lua_setfield(L, -2, "open");
    lua_pushcfunction(L, tui::supported, "tui.supported");
    lua_setfield(L, -2, "supported");
    lua_pushcfunction(L, tui::measureText, "tui.measure");
    lua_setfield(L, -2, "measure");
    lua_pushcfunction(L, tui::clipText, "tui.clip");
    lua_setfield(L, -2, "clip");
    lua_setreadonly(L, -1, 1);
    return 1;
}
