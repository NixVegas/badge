idf_component_register(SRCS "stub.c"
                       PRIV_REQUIRES esp-tls esp_driver_rmt esp_driver_gpio esp_driver_uart esp_wifi esp_http_client esp_http_server nvs_flash
                       INCLUDE_DIRS ".")

include(../cmake/zig-build.cmake)
