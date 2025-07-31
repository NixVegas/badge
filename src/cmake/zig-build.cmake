# Zig Build Configuration

if(CONFIG_IDF_TARGET_ARCH_RISCV)
    set(ZIG_TARGET "riscv32-freestanding-none")
    if(CONFIG_IDF_TARGET_ESP32C6 OR CONFIG_IDF_TARGET_ESP32C5 OR CONFIG_IDF_TARGET_ESP32H2)
        set(TARGET_CPU_MODEL "generic_rv32+m+a+c+zicsr+zifencei")
    else()
        set(TARGET_CPU_MODEL "generic_rv32+m+c+zicsr+zifencei")
    endif()
else()
    message(FATAL_ERROR "Unsupported target ${CONFIG_IDF_TARGET}")
endif()

if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(ZIG_BUILD_TYPE "Debug")
else()
    set(ZIG_BUILD_TYPE "ReleaseSafe")
endif()

if(CONFIG_BADGE_HW_REV_0_5 STREQUAL "y")
    set(BOARD_REV "0.5")
elseif(CONFIG_BADGE_HW_REV_1_0 STREQUAL "y")
    set(BOARD_REV "1.0")
else()
    message(FATAL_ERROR "Unrecognized hardware revision configured")
endif()

set(include_dirs $<TARGET_PROPERTY:${COMPONENT_LIB},INCLUDE_DIRECTORIES> ${CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES})
add_custom_target(zig_build
    COMMAND ${CMAKE_COMMAND} -E env
    "INCLUDE_DIRS=${include_dirs}"
    zig build
    --build-file ${CMAKE_SOURCE_DIR}/build.zig
    -Doptimize=${ZIG_BUILD_TYPE}
    -Dtarget=${ZIG_TARGET}
    -Dcpu=${TARGET_CPU_MODEL}
    -Desp-idf-source=$ENV{IDF_PATH}
    -Desp-idf-build=${CMAKE_BINARY_DIR}/esp-idf
    -Dboard-rev=${BOARD_REV}
    -freference-trace
    --prominent-compile-errors
    --cache-dir ${CMAKE_BINARY_DIR}/zig-cache
    --prefix ${CMAKE_BINARY_DIR}
    DEPENDS
      ${CMAKE_BINARY_DIR}/esp-idf/esp_driver_uart/libesp_driver_uart.a
      ${CMAKE_BINARY_DIR}/esp-idf/esp_system/libesp_system.a
      ${CMAKE_BINARY_DIR}/esp-idf/esp_wifi/libesp_wifi.a
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    BYPRODUCTS ${CMAKE_BINARY_DIR}/lib/libnixbadge_zig.a
    VERBATIM)

add_prebuilt_library(zig ${CMAKE_BINARY_DIR}/lib/libnixbadge_zig.a)
add_dependencies(${COMPONENT_LIB} zig_build)
target_link_libraries(${COMPONENT_LIB} PRIVATE ${CMAKE_BINARY_DIR}/lib/libnixbadge_zig.a)
