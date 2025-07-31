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

static bool is_running = true;
static bool is_mesh_connected = false;
static mesh_addr_t mesh_parent_addr;
static int mesh_layer = -1;
static esp_netif_t *netif_sta = NULL;
int64_t last_ping_timestamp = 0;

/* Zig functions */
extern uint8_t *nixbadge_mesh_create_packet(uint8_t, uint16_t *);

extern void nixbadge_mesh_read_packet(uint8_t *, uint16_t, mesh_addr_t);
extern uint8_t *nixbadge_mesh_alloc_read(uint16_t *);
extern void nixbadge_mesh_remove_peer(mesh_addr_t);

/* C functions */

esp_err_t nixbadge_mesh_send_packet(const mesh_addr_t *to, uint8_t kind) {
  if (to != NULL)
    ESP_LOGI(TAG, "Sending to " MACSTR " with %d", MAC2STR(to->addr), kind);

  mesh_data_t data;
  data.data = nixbadge_mesh_create_packet(kind, &data.size);
  data.proto = MESH_PROTO_BIN;
  data.tos = MESH_TOS_P2P;

  return esp_mesh_send(to, &data, to == NULL ? 0 : MESH_DATA_P2P, NULL, 0);
}

esp_err_t nixbadge_mesh_recv_packet(int timeout_ms) {
  mesh_data_t data;
  data.data = nixbadge_mesh_alloc_read(&data.size);
  data.proto = MESH_PROTO_BIN;
  data.tos = MESH_TOS_P2P;

  int flag = 0;
  mesh_addr_t from;
  esp_err_t err = esp_mesh_recv(&from, &data, timeout_ms, &flag, NULL, 0);
  if (err != ESP_OK || !data.size) {
    ESP_LOGE(TAG, "err:0x%x, size:%d", err, data.size);
    return err;
  }

  nixbadge_mesh_read_packet(data.data, data.size, from);
  return ESP_OK;
}

void nixbadge_mesh_set_softap_info() {
  char softap_ssid[33];
  char softap_psw[64];

  size_t ssid_size;
  size_t psw_size;

  if (esp_mesh_lite_get_softap_ssid_from_nvs(softap_ssid, &ssid_size) !=
      ESP_OK) {
    uint8_t softap_mac[6];
    esp_wifi_get_mac(WIFI_IF_AP, softap_mac);

    snprintf(softap_ssid, sizeof(softap_ssid), "%.25s_%02x%02x%02x",
             CONFIG_BRIDGE_SOFTAP_SSID, softap_mac[3], softap_mac[4],
             softap_mac[5]);
  }

  if (esp_mesh_lite_get_softap_psw_from_nvs(softap_psw, &psw_size) != ESP_OK) {
    strlcpy(softap_psw, CONFIG_BRIDGE_SOFTAP_PASSWORD, sizeof(softap_psw));
  }

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

void nixbadge_mesh_init() {
  // Load configuration
  esp_bridge_create_all_netif();

  size_t router_ssid_len = 32;
  uint8_t *router_ssid =
      nixbadge_mesh_read_nvs("router_ssid", &router_ssid_len);

  size_t router_passwd_len = 64;
  uint8_t *router_passwd =
      nixbadge_mesh_read_nvs("router_passwd", &router_passwd_len);

  ESP_LOGI(TAG, "%p", router_passwd);

  wifi_config_t wifi_config = {
      .sta = {},
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

  esp_mesh_lite_start();
}
