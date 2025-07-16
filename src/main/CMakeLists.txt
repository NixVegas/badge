idf_component_register(SRCS "nixbadge.c" "led_strip_encoder.c"
                       PRIV_REQUIRES esp_driver_rmt esp_driver_gpio
                       INCLUDE_DIRS ".")
