# The following lines of boilerplate have to be in your project's CMakeLists
# in this exact order for cmake to work correctly
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# "Trim" the build. Include the minimal set of components, main, and anything it depends on.
idf_build_set_property(MINIMAL_BUILD ON)
# Wrap the final ELF link in --start-group so the linker can rescan archives
# to resolve mutual references between libmain (the C bitfield helpers) and
# libnixbadge_zig (everything else implemented in Zig).
set(__PROJECT_GROUP_LINK_COMPONENTS 1)
project(nixbadge)
