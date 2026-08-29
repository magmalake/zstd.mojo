cmake_minimum_required(VERSION 3.16)
project(zstdmojo C)

# conda-forge's zstd package ships a CMake package-config (zstdConfig.cmake),
# not a bundled Find module — unlike zlib. pixi-build-cmake puts the host
# env's prefix on CMAKE_PREFIX_PATH, so this resolves the same way zlib.mojo's
# `find_package(ZLIB REQUIRED)` does.
find_package(zstd CONFIG REQUIRED)

add_library(zstdmojo SHARED zstd_wrapper.c)
target_link_libraries(zstdmojo PRIVATE zstd::libzstd)
# _find_lib() in the Mojo package loads lib/libzstdmojo.so on every platform.
set_target_properties(zstdmojo PROPERTIES SUFFIX ".so" PREFIX "lib")

install(TARGETS zstdmojo LIBRARY DESTINATION lib)
