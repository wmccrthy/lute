#include "lute/tuicore.h"

#include <algorithm>
#include <charconv>
#include <tuple>

namespace tui
{
namespace
{
// A strict scalar decoder: incomplete input consumes nothing; malformed input
// consumes one byte. This keeps chunk boundaries out of the public API.
size_t decode(std::string_view s, uint32_t& cp)
{
    unsigned char c = s[0];
    size_t n = c < 0x80 ? 1 : c >= 0xc2 && c <= 0xdf ? 2 : c >= 0xe0 && c <= 0xef ? 3 : c >= 0xf0 && c <= 0xf4 ? 4 : 0;
    cp = 0xfffd;
    if (!n)
        return 1;
    for (size_t i = 1; i < std::min(n, s.size()); ++i)
        if ((static_cast<unsigned char>(s[i]) & 0xc0) != 0x80)
            return 1;
    if (s.size() < n)
        return 0;
    uint32_t value = c & (n == 1 ? 0x7f : (1 << (7 - n)) - 1);
    for (size_t i = 1; i < n; ++i)
        value = (value << 6) | (s[i] & 0x3f);
    if ((n == 2 && value < 0x80) || (n == 3 && value < 0x800) || (n == 4 && value < 0x10000) || value > 0x10ffff ||
        (value >= 0xd800 && value <= 0xdfff))
        return 1;
    cp = value;
    return n;
}

struct Interval
{
    uint32_t first, last;
};
#include "widths.inc"

template<size_t N>
bool contains(const Interval (&ranges)[N], uint32_t cp)
{
    auto it = std::lower_bound(
        std::begin(ranges),
        std::end(ranges),
        cp,
        [](const Interval& range, uint32_t value)
        {
            return range.last < value;
        }
    );
    return it != std::end(ranges) && it->first <= cp;
}

int cellWidth(uint32_t cp)
{
    if (cp < 32 || (cp >= 0x7f && cp < 0xa0))
        return -1;
    if (contains(zeroWidth, cp))
        return 0;
    return contains(wideWidth, cp) ? 2 : 1;
}

void modifiers(Event& event, int value)
{
    if (value < 1 || value > 8)
        return;
    --value;
    event.shift = value & 1;
    event.alt = value & 2;
    event.ctrl = value & 4;
}

std::vector<int> parameters(std::string_view text)
{
    std::vector<int> result;
    while (!text.empty())
    {
        auto end = text.find(';');
        auto part = text.substr(0, end);
        int value = 0;
        auto conversion = std::from_chars(part.data(), part.data() + part.size(), value);
        if (conversion.ec != std::errc() || conversion.ptr != part.data() + part.size())
            return {};
        result.push_back(value);
        if (end == std::string_view::npos)
            break;
        text.remove_prefix(end + 1);
    }
    return result;
}

std::string keyFor(char final)
{
    switch (final)
    {
    case 'A':
        return "up";
    case 'B':
        return "down";
    case 'C':
        return "right";
    case 'D':
        return "left";
    case 'H':
        return "home";
    case 'F':
        return "end";
    case 'P':
        return "f1";
    case 'Q':
        return "f2";
    case 'R':
        return "f3";
    case 'S':
        return "f4";
    default:
        return "";
    }
}

std::string styleSequence(const Style& s)
{
    std::string out = "\x1b[0";
    if (s.bold)
        out += ";1";
    if (s.dim)
        out += ";2";
    if (s.italic)
        out += ";3";
    if (s.underline)
        out += ";4";
    if (s.reverse)
        out += ";7";
    auto color = [&](int value, int channel)
    {
        if (value < 0)
            return;
        out += ";" + std::to_string(channel);
        if (value <= 255)
            out += ";5;" + std::to_string(value);
        else
            out += ";2;" + std::to_string((value >> 16) & 255) + ";" + std::to_string((value >> 8) & 255) + ";" + std::to_string(value & 255);
    };
    color(s.fg, 38);
    color(s.bg, 48);
    return out + "m";
}
} // namespace

void Input::emit(Event event)
{
    if (events.size() >= maxEvents)
        throw std::runtime_error("tui input event queue overflow");
    events.push_back(std::move(event));
}

bool Input::waitingEscape() const
{
    return !paste && !pending.empty() && pending[0] == '\x1b';
}

void Input::expireEscape()
{
    if (!waitingEscape())
        return;
    Event event;
    event.key = "escape";
    emit(std::move(event));
    pending.erase(0, 1);
    feed({});
}

void Input::feed(std::string_view bytes)
{
    pending.append(bytes);
    size_t offset = 0;
    while (offset < pending.size())
    {
        std::string_view s(pending.data() + offset, pending.size() - offset);
        if (paste)
        {
            auto end = s.find("\x1b[201~", pasteSearch);
            if (end == std::string_view::npos)
            {
                size_t suffix = std::min(size_t(5), s.size());
                while (suffix && s.substr(s.size() - suffix) != std::string_view("\x1b[201~").substr(0, suffix))
                    --suffix;
                if (s.size() - suffix > maxPaste)
                    throw std::runtime_error("tui paste exceeds 1 MiB");
                pasteSearch = s.size() > 5 ? s.size() - 5 : 0;
                break;
            }
            if (end > maxPaste)
                throw std::runtime_error("tui paste exceeds 1 MiB");
            Event event;
            event.kind = "paste";
            event.text = std::string(s.substr(0, end));
            emit(std::move(event));
            offset += end + 6;
            paste = false;
            pasteSearch = 0;
            continue;
        }
        bool alt = false;
        size_t prefix = 0;
        if (s[0] == '\x1b')
        {
            if (s.size() == 1)
                break;
            if (s[1] == '[' || s[1] == 'O')
            {
                size_t end = 2;
                while (end < s.size() && !(s[end] >= 0x40 && s[end] <= 0x7e))
                    ++end;
                if (end == s.size())
                {
                    if (s.size() > 128)
                        throw std::runtime_error("tui escape sequence too long");
                    break;
                }
                if (end > 128)
                    throw std::runtime_error("tui escape sequence too long");
                auto body = s.substr(2, end - 2);
                char final = s[end];
                offset += end + 1;
                if (body == "200" && final == '~')
                {
                    paste = true;
                    continue;
                }
                Event event;
                bool mouse = !body.empty() && body[0] == '<';
                auto args = parameters(mouse ? body.substr(1) : body);
                if (mouse && args.size() == 3 && args[1] > 0 && args[2] > 0 && (final == 'M' || final == 'm'))
                {
                    int button = args[0];
                    event.kind = "mouse";
                    event.x = args[1];
                    event.y = args[2];
                    event.shift = button & 4;
                    event.alt = button & 8;
                    event.ctrl = button & 16;
                    event.button = (button & 3) == 3 ? 0 : (button & 3) + 1;
                    event.action = button & 64    ? ((button & 1) ? "scrolldown" : "scrollup")
                                   : final == 'm' ? "release"
                                   : button & 32  ? "move"
                                                  : "press";
                    emit(std::move(event));
                    continue;
                }
                event.key = keyFor(final);
                if (final == 'Z')
                {
                    event.key = "tab";
                    event.shift = true;
                }
                if (final == '~' && !args.empty())
                {
                    switch (args[0])
                    {
                    case 1:
                    case 7:
                        event.key = "home";
                        break;
                    case 2:
                        event.key = "insert";
                        break;
                    case 3:
                        event.key = "delete";
                        break;
                    case 4:
                    case 8:
                        event.key = "end";
                        break;
                    case 5:
                        event.key = "pageup";
                        break;
                    case 6:
                        event.key = "pagedown";
                        break;
                    case 11:
                    case 12:
                    case 13:
                    case 14:
                    case 15:
                        event.key = "f" + std::to_string(args[0] - 10);
                        break;
                    case 17:
                    case 18:
                    case 19:
                    case 20:
                    case 21:
                        event.key = "f" + std::to_string(args[0] - 11);
                        break;
                    case 23:
                    case 24:
                        event.key = "f" + std::to_string(args[0] - 12);
                        break;
                    }
                }
                if (args.size() == 2)
                    modifiers(event, args[1]);
                if (!event.key.empty() && !mouse && (body.empty() || !args.empty()))
                    emit(std::move(event));
                continue;
            }
            alt = true;
            prefix = 1;
            s.remove_prefix(1);
        }
        uint32_t cp;
        size_t length = decode(s, cp);
        if (!length)
            break;
        Event event;
        event.alt = alt;
        if (cp == 27)
            event.key = "escape";
        else if (cp == 13 || cp == 10)
            event.key = "enter";
        else if (cp == 9)
            event.key = "tab";
        else if (cp == 127 || cp == 8)
            event.key = "backspace";
        else if (cp < 32)
        {
            event.ctrl = true;
            if (cp == 0)
                event.key = "space";
            else
                event.key = std::string(1, cp <= 26 ? char(cp + 96) : char(cp + 64));
        }
        else
        {
            event.text = cp == 0xfffd ? "\xef\xbf\xbd" : std::string(s.substr(0, length));
            event.key = event.text == " " ? "space" : event.text;
        }
        emit(std::move(event));
        offset += prefix + length;
    }
    pending.erase(0, offset);
}

bool Style::operator==(const Style& s) const
{
    return std::tie(fg, bg, bold, dim, italic, underline, reverse) == std::tie(s.fg, s.bg, s.bold, s.dim, s.italic, s.underline, s.reverse);
}

bool Cell::operator==(const Cell& c) const
{
    return text == c.text && width == c.width && style == c.style;
}

Screen::Screen(int width, int height)
{
    resize(width, height);
}

void Screen::resize(int width, int height)
{
    if (width < 1 || height < 1 || width > 4096 || height > 4096 || size_t(width) * size_t(height) > 1024 * 1024)
        throw std::runtime_error("tui screen dimensions exceed limits");
    std::vector<Cell> replacement(size_t(width) * height);
    for (int y = 0; y < std::min(rows, height); ++y)
        for (int x = 0; x < std::min(columns, width); ++x)
        {
            const auto& cell = cells[size_t(y) * columns + x];
            if (cell.width == 2 && x + 1 >= width)
                continue;
            replacement[size_t(y) * width + x] = cell;
        }
    columns = width;
    rows = height;
    cells = std::move(replacement);
    previous.resize(cells.size());
    invalid = true;
}

const Cell& Screen::at(int x, int y) const
{
    return cells.at(size_t(y - 1) * columns + x - 1);
}
void Screen::clear()
{
    std::fill(cells.begin(), cells.end(), Cell{});
}
void Screen::invalidate()
{
    invalid = true;
}

void Screen::eraseGlyph(int x, int y)
{
    auto i = size_t(y) * columns + x;
    if (cells[i].width == 0 && x > 0)
        cells[i - 1] = Cell{};
    if (cells[i].width == 2 && x + 1 < columns)
        cells[i + 1] = Cell{};
    cells[i] = Cell{};
}

void Screen::text(int x, int y, std::string_view value, Style style)
{
    --x;
    --y;
    const int origin = x;
    while (!value.empty())
    {
        uint32_t cp;
        size_t n = decode(value, cp);
        if (!n)
        {
            n = value.size();
            cp = 0xfffd;
        }
        std::string glyph = cp == 0xfffd ? "\xef\xbf\xbd" : std::string(value.substr(0, n));
        value.remove_prefix(n);
        if (cp == '\n')
        {
            x = origin;
            ++y;
            continue;
        }
        int width = cellWidth(cp);
        if (width < 0)
            continue; // Never allow application text to inject controls.
        if (y >= rows)
            break;
        if (width == 0)
        {
            if (y >= 0 && x > 0 && x <= columns)
            {
                int previousX = x - 1;
                if (cells[size_t(y) * columns + previousX].width == 0)
                    --previousX;
                if (previousX >= 0)
                    cells[size_t(y) * columns + previousX].text += glyph;
            }
            continue;
        }
        if (y >= 0 && x >= 0 && x + width <= columns)
        {
            eraseGlyph(x, y);
            if (width == 2)
                eraseGlyph(x + 1, y);
            cells[size_t(y) * columns + x] = {std::move(glyph), style, width};
            if (width == 2)
                cells[size_t(y) * columns + x + 1] = {"", style, 0};
        }
        // Stop advancing once clipped, but keep scanning for a newline.
        x = std::min(columns + 1, x + width);
    }
}

std::string Screen::render()
{
    std::string out;
    Style current;
    bool haveStyle = false;
    int nextX = -1, nextY = -1;
    for (int y = 0; y < rows; ++y)
        for (int x = 0; x < columns; ++x)
        {
            size_t i = size_t(y) * columns + x;
            const auto& cell = cells[i];
            if (cell.width == 0 || (!invalid && cell == previous[i]))
                continue;
            if (x != nextX || y != nextY)
                out += "\x1b[" + std::to_string(y + 1) + ";" + std::to_string(x + 1) + "H";
            if (!haveStyle || !(current == cell.style))
            {
                out += styleSequence(cell.style);
                current = cell.style;
                haveStyle = true;
            }
            out += cell.text;
            nextX = x + cell.width;
            nextY = y;
        }
    if (!out.empty())
        out += "\x1b[0m";
    previous = cells;
    invalid = false;
    return out;
}
} // namespace tui
