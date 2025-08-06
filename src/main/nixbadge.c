/*
 * nixbadge
 * Nix Vegas - Rebuild the world!
 */

#include <math.h>
#include <string.h>

#include "driver/gpio.h"
#include "driver/rmt_tx.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_mesh.h"
#include "esp_mesh_internal.h"
#include "esp_wifi.h"
#include "nixbadge_gpio.h"
#include "nixbadge_http.h"
#include "nixbadge_leds.h"
#include "nixbadge_mesh.h"
#include "nixbadge_utils.h"
#include "nvs_flash.h"

#define EXAMPLE_ANGLE_INC_FRAME 0.02
#define EXAMPLE_FRAME_DURATION_MS 20


/**
 * Log tag.
 */
static const char TAG[] = "nixbadge";

void ip_event_handler(void *arg, esp_event_base_t event_base, int32_t event_id,
                      void *event_data) {
  ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
  ESP_LOGI(TAG, "<IP_EVENT_STA_GOT_IP>IP:" IPSTR, IP2STR(&event->ip_info.ip));
}

/**
 * Application main function.
 */
void app_main(void) {
  ESP_LOGI(TAG, "Hello world %llu", nixbadge_timestamp_now());

  esp_err_t ret = nvs_flash_init();
  if (ret == ESP_ERR_NVS_NO_FREE_PAGES ||
      ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_ERROR_CHECK(nvs_flash_erase());
    ret = nvs_flash_init();
  }
  ESP_ERROR_CHECK(ret);

  ESP_ERROR_CHECK(esp_netif_init());
  ESP_ERROR_CHECK(esp_event_loop_create_default());
  ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                             &ip_event_handler, NULL));

  wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
  ESP_ERROR_CHECK(esp_wifi_init(&cfg));
  ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_APSTA));
  ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_FLASH));

  uint8_t boot_mesh = 0;

  nvs_handle flashcfg_handle;
  ESP_ERROR_CHECK(nvs_open("config", NVS_READONLY, &flashcfg_handle));

  ESP_ERROR_CHECK(nvs_get_u8(flashcfg_handle, "boot_mesh", &boot_mesh));

  nvs_close(flashcfg_handle);

  int wireless_enable = boot_mesh || gpio_get_level(GPIO_INPUT_PIN);

  if (wireless_enable) {
    nixbadge_mesh_init();
    nixbadge_http_init();
  }

  ESP_LOGI(TAG, "Start LED rainbow chase");
  nixbadge_leds_init();

  float offset = 0;
  int64_t last_ping = nixbadge_timestamp_now();
  ESP_LOGI(TAG, "Mesh is %s", nixbadge_has_mesh() ? "enabled" : "disabled");

  while (true) {
    if (nixbadge_has_mesh()) {
      nixbadge_leds_pull();
      int64_t now = nixbadge_timestamp_now();
      int64_t time_delta = now - last_ping;
      if (((time_delta / 1000) % 5) == 0) {
        nixbadge_mesh_broadcast(0);
        last_ping = nixbadge_timestamp_now();
      }
    } else {
      nixbadge_leds_pulse(offset);
      offset += EXAMPLE_ANGLE_INC_FRAME;
      if (offset > 2 * M_PI) {
        offset -= 2 * M_PI;
      }
    }

    nixbadge_leds_sync();
    vTaskDelay(pdMS_TO_TICKS(EXAMPLE_FRAME_DURATION_MS));
  }
}
