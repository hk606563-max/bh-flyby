add_executable(bhtool BhTool.cpp)
target_include_directories(bhtool PRIVATE ../.. ../../core)
# -ffast-math/-O3 miscompiled the Settings enum insert in this TU; use plain -O2 here
set_source_files_properties(BhTool.cpp PROPERTIES COMPILE_OPTIONS "-O2;-fno-fast-math")
target_link_libraries(bhtool PRIVATE gui core ${wxWidgets_LIBRARIES})
