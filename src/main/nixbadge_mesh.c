#include "nixbadge_mesh.h"

#include "esp_log.h"
#include "esp_mac.h"
#include "esp_mesh.h"
#include "esp_mesh_internal.h"
#include "esp_wifi.h"
#include "nixbadge_utils.h"
#include "nvs_flash.h"

#define CONFIG_MESH_AP_CONNECTIONS 10
#define CONFIG_MESH_ROUTE_TABLE_SIZE 12

static const uint8_t MESH_ID[6] = {0x74, 0x6F, 0x6D, 0x62, 0x6F, 0x79};

static const char TAG[] = "nixbadge_mesh";

static bool is_running = true;
static bool is_mesh_connected = false;
static mesh_addr_t mesh_parent_addr;
static int mesh_layer = -1;
static esp_netif_t *netif_sta = NULL;
static int64_t last_ping_timestamp = 0;

static char *router_ssid = NULL;
static char *router_passwd = NULL;
static char *ap_passwd = NULL;

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

static void esp_mesh_p2p_tx_main(void *arg) {
  mesh_addr_t route_table[CONFIG_MESH_ROUTE_TABLE_SIZE];
  int route_table_size = 0;
  int send_count = 0;
  mesh_tx_pending_t pending;

  is_running = true;
  while (is_running) {
    esp_mesh_get_tx_pending(&pending);
    ESP_LOGW(TAG,
             "[TX-PENDING][L:%d]to_parent:%d, to_parent_p2p:%d, to_child:%d, "
             "to_child_p2p:%d, mgmt:%d, broadcast:%d",
             mesh_layer, pending.to_parent, pending.to_parent_p2p,
             pending.to_child, pending.to_child_p2p, pending.mgmt,
             pending.broadcast);

    ESP_ERROR_CHECK(esp_mesh_get_routing_table((mesh_addr_t *)&route_table,
                                               CONFIG_MESH_ROUTE_TABLE_SIZE * 6,
                                               &route_table_size));

    int64_t now = nixbadge_ts();
    int64_t time_delta = now - last_ping_timestamp;

    ESP_LOGI(TAG, "Time since last ping: %" PRIi64, time_delta);

    if ((time_delta / 1000 % 30) == 0) {
      send_count++;
      for (int i = 0; i < route_table_size; i++) {
        ESP_LOGW(TAG, "" MACSTR ", %d", MAC2STR(route_table[i].addr), 1);
        esp_err_t err = nixbadge_mesh_send_packet(&route_table[i], 1);
        ESP_LOGI(TAG, "Sending to " MACSTR "", MAC2STR(route_table[i].addr));
        if (err) {
          ESP_LOGE(TAG,
                   "[ROOT-2-UNICAST:%d][L:%d]parent:" MACSTR " to " MACSTR
                   ", heap:%" PRId32 "[err:0x%x]",
                   send_count, mesh_layer, MAC2STR(mesh_parent_addr.addr),
                   MAC2STR(route_table[i].addr),
                   esp_get_minimum_free_heap_size(), err);
        } else {
          ESP_LOGW(TAG,
                   "[ROOT-2-UNICAST:%d][L:%d][rtableSize:%d]parent:" MACSTR
                   " to " MACSTR ", heap:%" PRId32 "[err:0x%x]",
                   send_count, mesh_layer, esp_mesh_get_routing_table_size(),
                   MAC2STR(mesh_parent_addr.addr), MAC2STR(route_table[i].addr),
                   esp_get_minimum_free_heap_size(), err);
        }
      }

      last_ping_timestamp = now;
    }

    esp_mesh_get_tx_pending(&pending);
    ESP_LOGW(TAG,
             "[TX-PENDING][L:%d]to_parent:%d, to_parent_p2p:%d, to_child:%d, "
             "to_child_p2p:%d, mgmt:%d, broadcast:%d",
             mesh_layer, pending.to_parent, pending.to_parent_p2p,
             pending.to_child, pending.to_child_p2p, pending.mgmt,
             pending.broadcast);

    if (route_table_size < 10) {
      vTaskDelay(1 * 1000 / portTICK_PERIOD_MS);
    }
  }
  vTaskDelete(NULL);
}

static void esp_mesh_p2p_rx_main(void *arg) {
  mesh_rx_pending_t pending;
  is_running = true;
  while (is_running) {
    esp_mesh_get_rx_pending(&pending);
    ESP_LOGW(TAG, "[RX-PENDING][L:%d]ds:%d, self:%d", mesh_layer, pending.toDS,
             pending.toSelf);
    if (pending.toSelf < 1) {
      vTaskDelay(10 * 1000 / portTICK_PERIOD_MS);
      continue;
    }

    esp_err_t err = nixbadge_mesh_recv_packet(portMAX_DELAY);
    if (err != ESP_OK) continue;
  }
  vTaskDelete(NULL);
}

static esp_err_t esp_mesh_comm_p2p_start(void) {
  static bool is_comm_p2p_started = false;
  if (!is_comm_p2p_started) {
    is_comm_p2p_started = true;
    xTaskCreate(esp_mesh_p2p_tx_main, "MPTX", 3072, NULL, 5, NULL);
    xTaskCreate(esp_mesh_p2p_rx_main, "MPRX", 3072, NULL, 5, NULL);
  }
  return ESP_OK;
}

static void mesh_connected_indicator(int i) {
  ESP_LOGI(TAG, "Mesh connected %d", i);
}

static void mesh_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data) {
  mesh_addr_t id = {
      0,
  };
  static int last_layer = 0;

  switch (event_id) {
    case MESH_EVENT_STARTED: {
      esp_mesh_get_id(&id);
      ESP_LOGI(TAG, "<MESH_EVENT_STARTED>ID:" MACSTR "", MAC2STR(id.addr));
      is_mesh_connected = false;
      mesh_layer = esp_mesh_get_layer();
    } break;
    case MESH_EVENT_STOPPED: {
      ESP_LOGI(TAG, "<MESH_EVENT_STOPPED>");
      is_mesh_connected = false;
      mesh_layer = esp_mesh_get_layer();
    } break;
    case MESH_EVENT_CHILD_CONNECTED: {
      mesh_event_child_connected_t *child_connected =
          (mesh_event_child_connected_t *)event_data;
      ESP_LOGI(TAG, "<MESH_EVENT_CHILD_CONNECTED>aid:%d, " MACSTR "",
               child_connected->aid, MAC2STR(child_connected->mac));
    } break;
    case MESH_EVENT_CHILD_DISCONNECTED: {
      mesh_event_child_disconnected_t *child_disconnected =
          (mesh_event_child_disconnected_t *)event_data;
      ESP_LOGI(TAG, "<MESH_EVENT_CHILD_DISCONNECTED>aid:%d, " MACSTR "",
               child_disconnected->aid, MAC2STR(child_disconnected->mac));
      mesh_addr_t addr;
      memcpy(&addr.addr, &child_disconnected->mac, sizeof (uint8_t[6]));
      nixbadge_mesh_remove_peer(addr);
    } break;
    case MESH_EVENT_ROUTING_TABLE_ADD: {
      mesh_event_routing_table_change_t *routing_table =
          (mesh_event_routing_table_change_t *)event_data;
      ESP_LOGW(TAG, "<MESH_EVENT_ROUTING_TABLE_ADD>add %d, new:%d",
               routing_table->rt_size_change, routing_table->rt_size_new);

    } break;
    case MESH_EVENT_ROUTING_TABLE_REMOVE: {
      mesh_event_routing_table_change_t *routing_table =
          (mesh_event_routing_table_change_t *)event_data;
      ESP_LOGW(TAG, "<MESH_EVENT_ROUTING_TABLE_REMOVE>remove %d, new:%d",
               routing_table->rt_size_change, routing_table->rt_size_new);
    } break;
    case MESH_EVENT_NO_PARENT_FOUND: {
      mesh_event_no_parent_found_t *no_parent =
          (mesh_event_no_parent_found_t *)event_data;
      ESP_LOGI(TAG, "<MESH_EVENT_NO_PARENT_FOUND>scan times:%d",
               no_parent->scan_times);
    }
    /* TODO handler for the failure */
    break;
    case MESH_EVENT_PARENT_CONNECTED: {
      mesh_event_connected_t *connected = (mesh_event_connected_t *)event_data;
      esp_mesh_get_id(&id);
      mesh_layer = connected->self_layer;
      memcpy(&mesh_parent_addr.addr, connected->connected.bssid, 6);
      ESP_LOGI(TAG,
               "<MESH_EVENT_PARENT_CONNECTED>layer:%d-->%d, parent:" MACSTR
               "%s, ID:" MACSTR "",
               last_layer, mesh_layer, MAC2STR(mesh_parent_addr.addr),
               esp_mesh_is_root()  ? "<ROOT>"
               : (mesh_layer == 2) ? "<layer2>"
                                   : "",
               MAC2STR(id.addr));
      last_layer = mesh_layer;
      is_mesh_connected = true;
      mesh_connected_indicator(mesh_layer);
      if (esp_mesh_is_root()) {
        esp_netif_dhcpc_stop(netif_sta);
        esp_netif_dhcpc_start(netif_sta);
      }
      esp_mesh_comm_p2p_start();
    } break;
    case MESH_EVENT_PARENT_DISCONNECTED: {
      mesh_event_disconnected_t *disconnected =
          (mesh_event_disconnected_t *)event_data;
      ESP_LOGI(TAG, "<MESH_EVENT_PARENT_DISCONNECTED>reason:%d",
               disconnected->reason);
      // mesh_disconnected_indicator();
      is_mesh_connected = false;
      mesh_layer = esp_mesh_get_layer();
    } break;
    case MESH_EVENT_LAYER_CHANGE: {
      mesh_event_layer_change_t *layer_change =
          (mesh_event_layer_change_t *)event_data;
      mesh_layer = layer_change->new_layer;
      ESP_LOGI(TAG, "<MESH_EVENT_LAYER_CHANGE>layer:%d-->%d%s", last_layer,
               mesh_layer,
               esp_mesh_is_root()  ? "<ROOT>"
               : (mesh_layer == 2) ? "<layer2>"
                                   : "");
      last_layer = mesh_layer;
      mesh_connected_indicator(mesh_layer);
    } break;
    case MESH_EVENT_ROOT_ADDRESS: {
      mesh_event_root_address_t *root_addr =
          (mesh_event_root_address_t *)event_data;
      ESP_LOGI(TAG, "<MESH_EVENT_ROOT_ADDRESS>root address:" MACSTR "",
               MAC2STR(root_addr->addr));
    } break;
    case MESH_EVENT_TODS_STATE: {
      mesh_event_toDS_state_t *toDs_state =
          (mesh_event_toDS_state_t *)event_data;
      ESP_LOGI(TAG, "<MESH_EVENT_TODS_REACHABLE>state:%d", *toDs_state);
    } break;
    case MESH_EVENT_ROOT_FIXED: {
      mesh_event_root_fixed_t *root_fixed =
          (mesh_event_root_fixed_t *)event_data;
      ESP_LOGI(TAG, "<MESH_EVENT_ROOT_FIXED>%s",
               root_fixed->is_fixed ? "fixed" : "not fixed");
    } break;
    case MESH_EVENT_SCAN_DONE: {
      mesh_event_scan_done_t *scan_done = (mesh_event_scan_done_t *)event_data;
      ESP_LOGI(TAG, "<MESH_EVENT_SCAN_DONE>number:%d", scan_done->number);
    } break;
    default:
      ESP_LOGD(TAG, "event id:%" PRId32 "", event_id);
      break;
  }
}

void nixbadge_mesh_init() {
  // Load configuration
  nvs_handle flashcfg_handle;
  ESP_ERROR_CHECK(nvs_open("config", NVS_READONLY, &flashcfg_handle));

  // Bring WiFi up
  wifi_init_config_t config = WIFI_INIT_CONFIG_DEFAULT();
  ESP_ERROR_CHECK(esp_wifi_init(&config));

  ESP_ERROR_CHECK(esp_netif_create_default_wifi_mesh_netifs(&netif_sta, NULL));

  ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_FLASH));
  ESP_ERROR_CHECK(esp_wifi_start());

  // Prepare mesh
  ESP_ERROR_CHECK(esp_mesh_init());
  ESP_ERROR_CHECK(esp_mesh_set_topology(MESH_TOPO_TREE));
  ESP_ERROR_CHECK(esp_mesh_set_vote_percentage(1));
  ESP_ERROR_CHECK(esp_mesh_set_xon_qsize(128));
  ESP_ERROR_CHECK(esp_event_handler_register(MESH_EVENT, ESP_EVENT_ANY_ID,
                                             &mesh_event_handler, NULL));

  // Configure mesh
  mesh_cfg_t cfg = MESH_INIT_CONFIG_DEFAULT();
  memcpy((uint8_t *)&cfg.mesh_id, MESH_ID, 6);

  ESP_ERROR_CHECK(nvs_get_u8(flashcfg_handle, "router_channel", &cfg.channel));

  cfg.router.ssid_len = 32;
  ESP_ERROR_CHECK(nvs_get_str(flashcfg_handle, "router_ssid",
                              (char *)&cfg.router.ssid,
                              (size_t *)&cfg.router.ssid_len));

  router_ssid = malloc(cfg.router.ssid_len);
  strncpy(router_ssid, (char *)cfg.router.ssid, cfg.router.ssid_len);

  size_t router_passwd_len = 64;
  ESP_ERROR_CHECK(nvs_get_str(flashcfg_handle, "router_passwd",
                              (char *)&cfg.router.password,
                              &router_passwd_len));

  router_passwd = malloc(router_passwd_len);
  strncpy(router_passwd, (char *)cfg.router.password, router_passwd_len);

  cfg.mesh_ap.max_connection = CONFIG_MESH_AP_CONNECTIONS;

  size_t ap_passwd_len = 64;
  ESP_ERROR_CHECK(nvs_get_str(flashcfg_handle, "ap_passwd",
                              (char *)&cfg.mesh_ap.password, &ap_passwd_len));

  ap_passwd = malloc(ap_passwd_len);
  strncpy(ap_passwd, (char *)cfg.mesh_ap.password, ap_passwd_len);

  // Close the flash handle before mesh goes up
  nvs_close(flashcfg_handle);

  // Apply config & bring mesh up
  ESP_ERROR_CHECK(esp_mesh_set_config(&cfg));
  ESP_ERROR_CHECK(esp_mesh_start());
}
