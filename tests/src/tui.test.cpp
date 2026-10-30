#include "lute/tuicore.h"

#include "doctest.h"

using namespace tui;

TEST_CASE("tui_input_is_independent_of_read_boundaries")
{
    const std::string bytes = "a\xc3\xa9\x1b[1;5A\x1bOP\x1b[200~hello\x1b[A\x1b[201~\x1b[<0;12;3M";
    for (size_t split = 0; split <= bytes.size(); ++split)
    {
        Input input;
        input.feed(bytes.substr(0, split));
        input.feed(bytes.substr(split));
        REQUIRE(input.events.size() == 6);
        CHECK(input.events[0].key == "a");
        CHECK(input.events[1].text == "\xc3\xa9");
        CHECK(input.events[2].key == "up");
        CHECK(input.events[2].ctrl);
        CHECK(input.events[3].key == "f1");
        CHECK(input.events[4].kind == "paste");
        CHECK(input.events[4].text == "hello\x1b[A");
        CHECK(input.events[5].kind == "mouse");
        CHECK(input.events[5].x == 12);
        CHECK(input.events[5].y == 3);
        CHECK(input.events[5].action == "press");
    }
}

TEST_CASE("tui_escape_controls_and_malformed_input")
{
    Input input;
    input.feed("\x1b");
    CHECK(input.events.empty());
    CHECK(input.waitingEscape());
    input.expireEscape();
    REQUIRE(input.events.size() == 1);
    CHECK(input.events.front().key == "escape");
    input.events.clear();
    input.feed("\x1bx\x03\r\t\x7f\xff\x1b[999~z");
    REQUIRE(input.events.size() == 7);
    CHECK(input.events[0].alt);
    CHECK(input.events[0].key == "x");
    CHECK(input.events[1].ctrl);
    CHECK(input.events[1].key == "c");
    CHECK(input.events[2].key == "enter");
    CHECK(input.events[3].key == "tab");
    CHECK(input.events[4].key == "backspace");
    CHECK(input.events[5].text == "\xef\xbf\xbd");
    CHECK(input.events[6].key == "z");
}

TEST_CASE("tui_input_memory_is_bounded")
{
    Input input;
    CHECK_THROWS_AS(input.feed("\x1b[200~" + std::string(Input::maxPaste + 1, 'x')), std::runtime_error);
    Input escape;
    CHECK_THROWS_AS(escape.feed("\x1b[" + std::string(129, '1') + "A"), std::runtime_error);
    Input keys;
    CHECK_THROWS_AS(keys.feed(std::string(Input::maxEvents + 1, 'x')), std::runtime_error);
}

TEST_CASE("tui_frames_diff_clip_and_erase_wide_cells")
{
    Screen screen(8, 3);
    screen.text(1, 1, "hello", {});
    CHECK(screen.render().find("hello") != std::string::npos);
    CHECK(screen.render().empty());
    screen.text(8, 1, "AB", {});
    const auto changed = screen.render();
    CHECK(changed.find("A") != std::string::npos);
    CHECK(changed.find("B") == std::string::npos);
    screen.clear();
    screen.text(1, 2, "\xe7\x95\x8c", {});
    screen.render();
    screen.text(2, 2, "x", {});
    CHECK(screen.at(1, 2).text == " ");
    CHECK(screen.at(2, 2).text == "x");
    screen.text(8, 2, "\xe7\x95\x8c", {});
    CHECK(screen.at(8, 2).text == " ");
    screen.text(1, 3, "e\xcc\x81", {});
    CHECK(screen.at(1, 3).text == "e\xcc\x81");
    screen.text(4, 3, "\x1b[31m", {});
    CHECK(screen.at(4, 3).text != "\x1b");
    CHECK_THROWS_AS(screen.resize(100000, 100000), std::runtime_error);
}

TEST_CASE("tui_styles_and_resize_force_a_complete_repaint")
{
    Screen screen(4, 2);
    Style style;
    style.fg = 2;
    style.bold = true;
    screen.text(1, 1, "ok", style);
    auto frame = screen.render();
    CHECK(frame.find("38;5;2") != std::string::npos);
    CHECK(screen.render().empty());
    screen.resize(5, 2);
    CHECK_FALSE(screen.render().empty());
}

TEST_CASE("tui_measurement_and_cell_slicing_match_native_widths")
{
    auto size = measure("a\xe7\x95\x8c\nhello");
    CHECK(size.first == 5);
    CHECK(size.second == 2);
    CHECK(
        clip(
            "a\xe7\x95\x8c"
            "e\xcc\x81",
            2,
            2
        ) == " e\xcc\x81"
    );
    CHECK(clip("\xe7\x95\x8c", 1, 0).empty());
    CHECK(clip("e\xcc\x81!", 1, 0) == "e\xcc\x81");
    CHECK(clip("a\x1b\nignored", 10, 0) == "a");
}

TEST_CASE("tui_dirty_rows_avoid_full_frame_scans_and_fill_repairs_wide_edges")
{
    Screen screen(80, 24);
    screen.render();
    CHECK(screen.scannedCells() == 80 * 24);
    CHECK(screen.render().empty());
    CHECK(screen.scannedCells() == 0);
    screen.text(2, 12, "one row", {});
    screen.render();
    CHECK(screen.scannedCells() == 80);
    screen.text(2, 12, "\xe7\x95\x8c", {});
    screen.fill(3, 12, 1, 1, {});
    CHECK(screen.at(2, 12).text == " ");
    CHECK(screen.at(3, 12).text == " ");
    screen.resize(20, 8);
    screen.render();
    CHECK(screen.scannedCells() == 20 * 8);
}
