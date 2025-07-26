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
#include "nixbadge_leds.h"
#include "nixbadge_mesh.h"
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

  nixbadge_mesh_init();

  ESP_LOGI(TAG, "Start LED rainbow chase");
  nixbadge_leds_init();

  float offset = 0;
  while (true) {
    nixbadge_leds_pulse(offset);
    vTaskDelay(pdMS_TO_TICKS(EXAMPLE_FRAME_DURATION_MS));

    float avg_ping = nixbadge_mesh_avg_ping();
    ESP_LOGI(TAG, "Average ping: %f", avg_ping);

    // Increase offset to shift pattern
    offset += avg_ping / EXAMPLE_FRAME_DURATION_MS;
    if (offset > 2 * M_PI) {
      offset -= 2 * M_PI;
    }
  }
}
