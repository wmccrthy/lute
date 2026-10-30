#pragma once

#include <cstdint>
#include <deque>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace tui
{
std::pair<int, int> measure(std::string_view value);
std::string clip(std::string_view value, int width, int offset = 0);

struct Event
{
    std::string kind = "key";
    std::string key, text, action;
    int x = 0, y = 0, button = 0;
    bool ctrl = false, alt = false, shift = false;
};

class Input
{
public:
    static constexpr size_t maxPaste = 1024 * 1024;
    static constexpr size_t maxEvents = 1024;
    void feed(std::string_view bytes);
    bool waitingEscape() const;
    void expireEscape();
    std::deque<Event> events;

private:
    void emit(Event event);
    std::string pending;
    bool paste = false;
    size_t pasteSearch = 0;
};

struct Style
{
    // -1: terminal default; 0..255: indexed; 0x1000000 | RGB: true color.
    int fg = -1, bg = -1;
    bool bold = false, dim = false, italic = false, underline = false, reverse = false;
    bool operator==(const Style& other) const;
};

struct Cell
{
    std::string text = " ";
    Style style;
    int width = 1;
    bool operator==(const Cell& other) const;
};

class Screen
{
public:
    Screen(int width, int height);
    void resize(int width, int height);
    void clear();
    void fill(int x, int y, int width, int height, Style style);
    size_t scannedCells() const
    {
        return scanned;
    }
    void text(int x, int y, std::string_view value, Style style);
    // Rendering commits the diff. On an output failure invalidate before retrying.
    std::string render();
    void invalidate();
    const Cell& at(int x, int y) const;
    int width() const
    {
        return columns;
    }
    int height() const
    {
        return rows;
    }

private:
    void eraseGlyph(int x, int y);
    void markRow(int y);
    int columns = 0, rows = 0;
    bool invalid = true;
    std::vector<Cell> cells, previous;
    std::vector<bool> dirty;
    std::vector<int> dirtyRows;
    size_t scanned = 0;
};
} // namespace tui
