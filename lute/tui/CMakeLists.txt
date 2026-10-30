add_library(Lute.Tui STATIC
    include/lute/tui.h
    include/lute/tuicore.h
    src/core.cpp
    src/tui.cpp
    src/widths.inc
)
target_compile_features(Lute.Tui PUBLIC cxx_std_17)
target_include_directories(Lute.Tui PUBLIC include)
target_link_libraries(Lute.Tui PRIVATE Lute.Runtime Luau.VM uv_a)
target_compile_options(Lute.Tui PRIVATE ${LUTE_OPTIONS})
