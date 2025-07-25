idf_component_register(SRCS "nixbadge.c" "nixbadge_mesh.c" "nixbadge_utils.c" "led_strip_encoder.c"
                       PRIV_REQUIRES esp_driver_rmt esp_driver_gpio esp_driver_uart esp_wifi nvs_flash
                       INCLUDE_DIRS ".")

include(../cmake/zig-build.cmake)
