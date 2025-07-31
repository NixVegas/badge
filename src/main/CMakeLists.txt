idf_component_register(SRCS "nixbadge.c" "nixbadge_mesh.c" "nixbadge_leds.c" "nixbadge_http.c" "nixbadge_utils.c" "led_strip_encoder.c"
                       PRIV_REQUIRES esp-tls esp_driver_rmt esp_driver_gpio esp_driver_uart esp_wifi esp_http_client esp_http_server nvs_flash
                       INCLUDE_DIRS ".")

include(../cmake/zig-build.cmake)
