#include "nixbadge_mesh.h"

#include "esp_bridge.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_mesh.h"
#include "esp_mesh_internal.h"
#include "esp_mesh_lite.h"
#include "esp_wifi.h"
#include "nixbadge_utils.h"
#include "nvs_flash.h"

#define CONFIG_MESH_AP_CONNECTIONS 10
#define CONFIG_MESH_ROUTE_TABLE_SIZE 12

static const char TAG[] = "nixbadge_mesh";

static esp_netif_t *netif_sta = NULL;
static bool is_meshing = false;
int64_t last_ping_timestamp = 0;

/* Zig functions */
extern uint8_t *nixbadge_mesh_create_packet(uint8_t, uint32_t *);

extern esp_err_t nixbadge_mesh_action_cb(uint8_t *data, uint32_t len,
                                         uint8_t **out_data, uint32_t *out_len,
                                         uint32_t seq);

/* C functions */

esp_err_t nixbadge_mesh_broadcast(uint8_t kind) {
  uint32_t size = 0;
  uint8_t *data = nixbadge_mesh_create_packet(kind, &size);

  esp_err_t err = esp_mesh_lite_send_broadcast_raw_msg_to_child(data, size);
  if (err != ESP_OK) return err;

  if (esp_mesh_lite_get_level() != ROOT)
    return esp_mesh_lite_send_broadcast_raw_msg_to_parent(data, size);
  return ESP_OK;
}

static const esp_mesh_lite_raw_msg_action_t nixbadge_mesh_action = {
    .msg_id = 0,
    .resp_msg_id = 0,
    .raw_process = nixbadge_mesh_action_cb,
};

void nixbadge_mesh_set_softap_info() {
  char softap_ssid[33];
  char softap_psw[64];

  size_t ssid_size;
  size_t psw_size;

  if (esp_mesh_lite_get_softap_ssid_from_nvs(softap_ssid, &ssid_size) !=
      ESP_OK) {
    uint8_t softap_mac[6];
    esp_wifi_get_mac(WIFI_IF_AP, softap_mac);

#ifdef CONFIG_BRIDGE_SOFTAP_SSID_END_WITH_THE_MAC
    snprintf(softap_ssid, sizeof(softap_ssid), "%.25s_%02X%02X%02X",
             CONFIG_BRIDGE_SOFTAP_SSID, softap_mac[3], softap_mac[4],
             softap_mac[5]);
#else
    snprintf(softap_ssid, sizeof(softap_ssid), "%.25s",
             CONFIG_BRIDGE_SOFTAP_SSID);
#endif
  }

  if (esp_mesh_lite_get_softap_psw_from_nvs(softap_psw, &psw_size) != ESP_OK) {
    strlcpy(softap_psw, CONFIG_BRIDGE_SOFTAP_PASSWORD, sizeof(softap_psw));
  }

  ESP_LOGI(TAG, "Serving SoftAP as %s", softap_ssid);

  esp_mesh_lite_set_softap_info(softap_ssid, softap_psw);
}

static uint8_t *nixbadge_mesh_read_nvs(const char *key, size_t *len) {
  nvs_handle flashcfg_handle;
  ESP_ERROR_CHECK(nvs_open("config", NVS_READONLY, &flashcfg_handle));

  uint8_t *value = malloc(*len);
  ESP_ERROR_CHECK(nvs_get_str(flashcfg_handle, key, (char *)value, len));

  nvs_close(flashcfg_handle);
  return value;
}

esp_ip4_addr_t nixbadge_mesh_get_gateway() {
  esp_netif_ip_info_t ip_info;
  esp_netif_get_ip_info(netif_sta, &ip_info);
  return ip_info.gw;
}

bool nixbadge_has_mesh() { return is_meshing; }

void nixbadge_mesh_init() {
  is_meshing = true;

  // Load configuration
  esp_bridge_create_softap_netif(NULL, NULL, true, true);
  netif_sta = esp_bridge_create_station_netif(NULL, NULL, false, false);

  size_t router_ssid_len = 32;
  uint8_t *router_ssid =
      nixbadge_mesh_read_nvs("router_ssid", &router_ssid_len);

  size_t router_passwd_len = 64;
  uint8_t *router_passwd =
      nixbadge_mesh_read_nvs("router_passwd", &router_passwd_len);

  wifi_config_t wifi_config = {
      .sta =
          {
              .pmf_cfg =
                  {
                      .required = true,
                  },
          },
  };
  memcpy(&wifi_config.sta.ssid, router_ssid, router_ssid_len);
  memcpy(&wifi_config.sta.password, router_passwd, router_passwd_len);
  esp_bridge_wifi_set_config(WIFI_IF_STA, &wifi_config);

  wifi_config_t wifi_softap_config = {
      .ap =
          {
              .ssid = CONFIG_BRIDGE_SOFTAP_SSID,
              .password = CONFIG_BRIDGE_SOFTAP_PASSWORD,
          },
  };
  esp_bridge_wifi_set_config(WIFI_IF_AP, &wifi_softap_config);

  esp_mesh_lite_config_t mesh_lite_config = ESP_MESH_LITE_DEFAULT_INIT();
  esp_mesh_lite_init(&mesh_lite_config);

  nixbadge_mesh_set_softap_info();

  ESP_ERROR_CHECK(
      esp_mesh_lite_raw_msg_action_list_register(&nixbadge_mesh_action));

  esp_mesh_lite_start();
}
