/*
 * nixbadge
 * Nix Vegas - Rebuild the world!
 */

#include <string.h>
#include <math.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"

#include "nvs_flash.h"
#include "esp_mac.h"
#include "esp_mesh_internal.h"
#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_mesh.h"
#include "driver/gpio.h"
#include "driver/rmt_tx.h"

#include "led_strip_encoder.h"

#define GPIO_INPUT_PIN 15
#define GPIO_INPUT_PIN_SEL  (1ULL << GPIO_INPUT_PIN)

#define GPIO_OUTPUT_PIN 23
#define GPIO_OUTPUT_PIN_SEL  (1ULL << GPIO_OUTPUT_PIN)

#define RMT_LED_STRIP_RESOLUTION_HZ 10000000 // 10MHz resolution, 1 tick = 0.1us (led strip needs a high resolution)
#define RMT_LED_STRIP_GPIO_NUM      14

#define EXAMPLE_LED_NUMBERS         12
#define EXAMPLE_FRAME_DURATION_MS   20
#define EXAMPLE_ANGLE_INC_FRAME     0.02
#define EXAMPLE_ANGLE_INC_LED       0.3

static const uint8_t MESH_ID[6] = { 0x74, 0x6F, 0x6D, 0x62, 0x6F, 0x79};

#define CONFIG_MESH_AP_CONNECTIONS 10
#define CONFIG_MESH_ROUTE_TABLE_SIZE 12

static bool is_running = true;
static bool is_mesh_connected = false;
static mesh_addr_t mesh_parent_addr;
static int mesh_layer = -1;
static esp_netif_t *netif_sta = NULL;
static int64_t last_ping_timestamp = 0;

static char* router_ssid = NULL;
static char* router_passwd = NULL;
static char* ap_passwd = NULL;

/**
 * Log tag.
 */
static const char TAG[] = "nixbadge";

static const char MESH_TAG[] = "nixbadge_mesh";

/**
 * Handle to the GPIO event queue.
 */
static QueueHandle_t gpio_evt_queue = NULL;

/**
 * GPIO interrupt handler. Just takes the GPIO that was signaled
 * and queues it.
 * @param arg the GPIO number
 */
static void IRAM_ATTR gpio_isr_handler(void *arg)
{
    uint32_t gpio_num = (uint32_t) arg;
    xQueueSendFromISR(gpio_evt_queue, &gpio_num, NULL);
}

/**
 * Task that receives GPIO interrupts.
 * @param arg the GPIO number
 */
static void gpio_task(void *arg) {
    uint32_t io_num;
    int cnt = 0;
    while (true) {
        if (xQueueReceive(gpio_evt_queue, &io_num, portMAX_DELAY)) {
            ESP_LOGI(TAG, "GPIO[%"PRIu32"] intr, val: %d", io_num, gpio_get_level(io_num));
            gpio_set_level(GPIO_OUTPUT_PIN, cnt++ % 2);
        }
    }
}

extern void setup_gpios_config();
extern uint8_t* write_mesh_packet(uint16_t*, uint8_t);
extern uint8_t* prepare_read_mesh_packet(uint16_t*);
extern void read_mesh_packet(uint8_t*, uint16_t, mesh_addr_t);

int64_t getTimestamp() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (tv.tv_sec * 1000LL + (tv.tv_usec / 1000LL));
}

esp_err_t owo_send_packet(const mesh_addr_t* to, uint8_t kind) {
    if (to != NULL) ESP_LOGI(MESH_TAG, "Sending to "MACSTR" with %d", MAC2STR(to->addr), kind);

    mesh_data_t data;
    data.data = write_mesh_packet(&data.size, kind);
    data.proto = MESH_PROTO_BIN;
    data.tos = MESH_TOS_P2P;

    return esp_mesh_send(to, &data, to == NULL ? 0 : MESH_DATA_P2P, NULL, 0);
}

esp_err_t owo_recv_packet(int timeout_ms) {
    mesh_data_t data;
    data.data = prepare_read_mesh_packet(&data.size);
    data.proto = MESH_PROTO_BIN;
    data.tos = MESH_TOS_P2P;

    int flag = 0;
    mesh_addr_t from;
    esp_err_t err = esp_mesh_recv(&from, &data, timeout_ms, &flag, NULL, 0);
    if (err != ESP_OK || !data.size) {
        ESP_LOGE(MESH_TAG, "err:0x%x, size:%d", err, data.size);
        return err;
    }

    read_mesh_packet(data.data, data.size, from);
    return ESP_OK;
}

/**
 * Sets up GPIOs. Starts gpio_task to handle GPIO interrupts.
 */
static void setup_gpios(void) {
    ESP_LOGI(TAG, "Setting up gpios...");
    setup_gpios_config();

    gpio_evt_queue = xQueueCreate(10, sizeof(uint32_t));
    xTaskCreate(gpio_task, "gpio_task", 2048, NULL, 10, NULL);
    gpio_isr_handler_add(GPIO_INPUT_PIN, gpio_isr_handler, (void*) GPIO_INPUT_PIN);
}

/**
 * Sets up the RMT.
 * @param led_chan the LED rmt channel handle
 * @param led_encoder the LED rmt encoder handle
 */
static void setup_rmt(rmt_channel_handle_t *led_chan, rmt_encoder_handle_t *led_encoder) {
    ESP_LOGI(TAG, "Create RMT TX channel");
    rmt_tx_channel_config_t tx_chan_config = {
        .clk_src = RMT_CLK_SRC_DEFAULT, // select source clock
        .gpio_num = RMT_LED_STRIP_GPIO_NUM,
        .mem_block_symbols = 64, // increase the block size can make the LED less flickering
        .resolution_hz = RMT_LED_STRIP_RESOLUTION_HZ,
        .trans_queue_depth = 4, // set the number of transactions that can be pending in the background
    };
    ESP_ERROR_CHECK(rmt_new_tx_channel(&tx_chan_config, led_chan));

    ESP_LOGI(TAG, "Install led strip encoder");

    led_strip_encoder_config_t encoder_config = {
        .resolution = RMT_LED_STRIP_RESOLUTION_HZ,
    };
    ESP_ERROR_CHECK(rmt_new_led_strip_encoder(&encoder_config, led_encoder));

    ESP_LOGI(TAG, "Enable RMT TX channel");
    ESP_ERROR_CHECK(rmt_enable(*led_chan));
}

void esp_mesh_p2p_tx_main(void* arg) {
    mesh_addr_t route_table[CONFIG_MESH_ROUTE_TABLE_SIZE];
    int route_table_size = 0;
    int send_count = 0;
    mesh_tx_pending_t pending;

    is_running = true;
    while (is_running) {
        esp_mesh_get_tx_pending(&pending);
        ESP_LOGW(MESH_TAG, "[TX-PENDING][L:%d]to_parent:%d, to_parent_p2p:%d, to_child:%d, to_child_p2p:%d, mgmt:%d, broadcast:%d",
            mesh_layer,
            pending.to_parent,
            pending.to_parent_p2p,
            pending.to_child,
            pending.to_child_p2p,
            pending.mgmt,
            pending.broadcast);

        ESP_ERROR_CHECK(esp_mesh_get_routing_table((mesh_addr_t *) &route_table,
                                   CONFIG_MESH_ROUTE_TABLE_SIZE * 6, &route_table_size));


        int64_t now = getTimestamp();
        int64_t time_delta = now - last_ping_timestamp;

        ESP_LOGI(MESH_TAG, "Time since last ping: %"PRIi64, time_delta);

        if ((time_delta / 1000 % 30) == 0) {
            send_count++;
            for (int i = 0; i < route_table_size; i++) {
                ESP_LOGW(MESH_TAG, ""MACSTR", %d", MAC2STR(route_table[i].addr), 1);
                esp_err_t err = owo_send_packet(&route_table[i], 1);
                ESP_LOGI(MESH_TAG, "Sending to "MACSTR"", MAC2STR(route_table[i].addr));
                if (err) {
                    ESP_LOGE(MESH_TAG,
                             "[ROOT-2-UNICAST:%d][L:%d]parent:"MACSTR" to "MACSTR", heap:%" PRId32 "[err:0x%x]",
                             send_count, mesh_layer, MAC2STR(mesh_parent_addr.addr),
                             MAC2STR(route_table[i].addr), esp_get_minimum_free_heap_size(),
                             err);
                } else {
                    ESP_LOGW(MESH_TAG,
                             "[ROOT-2-UNICAST:%d][L:%d][rtableSize:%d]parent:"MACSTR" to "MACSTR", heap:%" PRId32 "[err:0x%x]",
                             send_count, mesh_layer,
                             esp_mesh_get_routing_table_size(),
                             MAC2STR(mesh_parent_addr.addr),
                             MAC2STR(route_table[i].addr), esp_get_minimum_free_heap_size(),
                             err);
                }
            }

          last_ping_timestamp = now;
        }

        esp_mesh_get_tx_pending(&pending);
        ESP_LOGW(MESH_TAG, "[TX-PENDING][L:%d]to_parent:%d, to_parent_p2p:%d, to_child:%d, to_child_p2p:%d, mgmt:%d, broadcast:%d",
            mesh_layer,
            pending.to_parent,
            pending.to_parent_p2p,
            pending.to_child,
            pending.to_child_p2p,
            pending.mgmt,
            pending.broadcast);

        if (route_table_size < 10) {
            vTaskDelay(1 * 1000 / portTICK_PERIOD_MS);
        }
    }
    vTaskDelete(NULL);
}

void esp_mesh_p2p_rx_main(void* arg) {
    mesh_rx_pending_t pending;
    is_running = true;
    while (is_running) {
        esp_mesh_get_rx_pending(&pending);
        ESP_LOGW(MESH_TAG, "[RX-PENDING][L:%d]ds:%d, self:%d", mesh_layer, pending.toDS, pending.toSelf);
        if (pending.toSelf < 1) {
            vTaskDelay(10 * 1000 / portTICK_PERIOD_MS);
            continue;
        }

        esp_err_t err = owo_recv_packet(portMAX_DELAY);
        if (err != ESP_OK) continue;
    }
    vTaskDelete(NULL);
}

esp_err_t esp_mesh_comm_p2p_start(void) {
    static bool is_comm_p2p_started = false;
    if (!is_comm_p2p_started) {
        is_comm_p2p_started = true;
        xTaskCreate(esp_mesh_p2p_tx_main, "MPTX", 3072, NULL, 5, NULL);
        xTaskCreate(esp_mesh_p2p_rx_main, "MPRX", 3072, NULL, 5, NULL);
    }
    return ESP_OK;
}

void mesh_connected_indicator(int i) {
    ESP_LOGI(TAG, "Mesh connected %d", i);
}

extern void clear_peers();
extern void push_peer(mesh_addr_t addr, int8_t rssi);

void mesh_scan_done_handler(int num) {
    mesh_addr_t route_table[CONFIG_MESH_ROUTE_TABLE_SIZE];
    int route_table_size = 0;

    int ie_len = 0;
    mesh_assoc_t assoc;
    wifi_ap_record_t record;

    clear_peers();

    ESP_ERROR_CHECK(esp_mesh_get_routing_table((mesh_addr_t *) &route_table,
                    CONFIG_MESH_ROUTE_TABLE_SIZE * 6, &route_table_size));

    for (int i = 0; i < num; i++) {
        esp_mesh_scan_get_ap_ie_len(&ie_len);
        esp_mesh_scan_get_ap_record(&record, &assoc);

        if (i == sizeof(assoc)) {
            for (int x = 0; x < route_table_size; x++) {
                const mesh_addr_t* addr = &route_table[x];
                if (memcmp(&addr->addr, record.bssid, sizeof (uint8_t[6])) == 0) {
                    push_peer(*addr, record.rssi);
                    break;
                }
            }
        }
    }

    esp_mesh_flush_scan_result();
}

void rescan() {
    wifi_scan_config_t scan_config = { 0 };
    esp_wifi_scan_stop();
    scan_config.show_hidden = 1;
    scan_config.scan_type = WIFI_SCAN_TYPE_PASSIVE;
    esp_wifi_scan_start(&scan_config, 0);
}

void mesh_event_handler(void *arg, esp_event_base_t event_base,
                        int32_t event_id, void *event_data)
{
    mesh_addr_t id = {0,};
    static int last_layer = 0;

    switch (event_id) {
    case MESH_EVENT_STARTED: {
        esp_mesh_get_id(&id);
        ESP_LOGI(MESH_TAG, "<MESH_EVENT_STARTED>ID:"MACSTR"", MAC2STR(id.addr));
        is_mesh_connected = false;
        mesh_layer = esp_mesh_get_layer();
        rescan();
    }
    break;
    case MESH_EVENT_STOPPED: {
        ESP_LOGI(MESH_TAG, "<MESH_EVENT_STOPPED>");
        is_mesh_connected = false;
        mesh_layer = esp_mesh_get_layer();
    }
    break;
    case MESH_EVENT_CHILD_CONNECTED: {
        mesh_event_child_connected_t *child_connected = (mesh_event_child_connected_t *)event_data;
        ESP_LOGI(MESH_TAG, "<MESH_EVENT_CHILD_CONNECTED>aid:%d, "MACSTR"",
                 child_connected->aid,
                 MAC2STR(child_connected->mac));

        rescan();
    }
    break;
    case MESH_EVENT_CHILD_DISCONNECTED: {
        mesh_event_child_disconnected_t *child_disconnected = (mesh_event_child_disconnected_t *)event_data;
        ESP_LOGI(MESH_TAG, "<MESH_EVENT_CHILD_DISCONNECTED>aid:%d, "MACSTR"",
                 child_disconnected->aid,
                 MAC2STR(child_disconnected->mac));
        rescan();
    }
    break;
    case MESH_EVENT_ROUTING_TABLE_ADD: {
        mesh_event_routing_table_change_t *routing_table = (mesh_event_routing_table_change_t *)event_data;
        ESP_LOGW(MESH_TAG, "<MESH_EVENT_ROUTING_TABLE_ADD>add %d, new:%d",
                 routing_table->rt_size_change,
                 routing_table->rt_size_new);

        rescan();
    }
    break;
    case MESH_EVENT_ROUTING_TABLE_REMOVE: {
        mesh_event_routing_table_change_t *routing_table = (mesh_event_routing_table_change_t *)event_data;
        ESP_LOGW(MESH_TAG, "<MESH_EVENT_ROUTING_TABLE_REMOVE>remove %d, new:%d",
                 routing_table->rt_size_change,
                 routing_table->rt_size_new);
    }
    break;
    case MESH_EVENT_NO_PARENT_FOUND: {
        mesh_event_no_parent_found_t *no_parent = (mesh_event_no_parent_found_t *)event_data;
        ESP_LOGI(MESH_TAG, "<MESH_EVENT_NO_PARENT_FOUND>scan times:%d",
                 no_parent->scan_times);
    }
    /* TODO handler for the failure */
    break;
    case MESH_EVENT_PARENT_CONNECTED: {
        mesh_event_connected_t *connected = (mesh_event_connected_t *)event_data;
        esp_mesh_get_id(&id);
        mesh_layer = connected->self_layer;
        memcpy(&mesh_parent_addr.addr, connected->connected.bssid, 6);
        ESP_LOGI(MESH_TAG,
                 "<MESH_EVENT_PARENT_CONNECTED>layer:%d-->%d, parent:"MACSTR"%s, ID:"MACSTR"",
                 last_layer, mesh_layer, MAC2STR(mesh_parent_addr.addr),
                 esp_mesh_is_root() ? "<ROOT>" :
                 (mesh_layer == 2) ? "<layer2>" : "", MAC2STR(id.addr));
        last_layer = mesh_layer;
        is_mesh_connected = true;
        mesh_connected_indicator(mesh_layer);
        if (esp_mesh_is_root()) {
            esp_netif_dhcpc_stop(netif_sta);
            esp_netif_dhcpc_start(netif_sta);
        }
        esp_mesh_comm_p2p_start();
    }
    break;
    case MESH_EVENT_PARENT_DISCONNECTED: {
        mesh_event_disconnected_t *disconnected = (mesh_event_disconnected_t *)event_data;
        ESP_LOGI(MESH_TAG,
                 "<MESH_EVENT_PARENT_DISCONNECTED>reason:%d",
                 disconnected->reason);
        //mesh_disconnected_indicator();
        is_mesh_connected = false;
        mesh_layer = esp_mesh_get_layer();
    }
    break;
    case MESH_EVENT_LAYER_CHANGE: {
        mesh_event_layer_change_t *layer_change = (mesh_event_layer_change_t *)event_data;
        mesh_layer = layer_change->new_layer;
        ESP_LOGI(MESH_TAG, "<MESH_EVENT_LAYER_CHANGE>layer:%d-->%d%s",
                 last_layer, mesh_layer,
                 esp_mesh_is_root() ? "<ROOT>" :
                 (mesh_layer == 2) ? "<layer2>" : "");
        last_layer = mesh_layer;
        mesh_connected_indicator(mesh_layer);
    }
    break;
    case MESH_EVENT_ROOT_ADDRESS: {
        mesh_event_root_address_t *root_addr = (mesh_event_root_address_t *)event_data;
        ESP_LOGI(MESH_TAG, "<MESH_EVENT_ROOT_ADDRESS>root address:"MACSTR"",
                 MAC2STR(root_addr->addr));
    }
    break;
    case MESH_EVENT_TODS_STATE: {
        mesh_event_toDS_state_t *toDs_state = (mesh_event_toDS_state_t *)event_data;
        ESP_LOGI(MESH_TAG, "<MESH_EVENT_TODS_REACHABLE>state:%d", *toDs_state);
    }
    break;
    case MESH_EVENT_ROOT_FIXED: {
        mesh_event_root_fixed_t *root_fixed = (mesh_event_root_fixed_t *)event_data;
        ESP_LOGI(MESH_TAG, "<MESH_EVENT_ROOT_FIXED>%s",
                 root_fixed->is_fixed ? "fixed" : "not fixed");
    }
    break;
    case MESH_EVENT_SCAN_DONE: {
        mesh_event_scan_done_t *scan_done = (mesh_event_scan_done_t *)event_data;
        ESP_LOGI(MESH_TAG, "<MESH_EVENT_SCAN_DONE>number:%d",
                 scan_done->number);
        mesh_scan_done_handler(scan_done->number);
    }
    break;
    default:
        ESP_LOGD(MESH_TAG, "event id:%" PRId32 "", event_id);
        break;
    }
}

void ip_event_handler(void *arg, esp_event_base_t event_base,
                      int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *event = (ip_event_got_ip_t *) event_data;
    ESP_LOGI(MESH_TAG, "<IP_EVENT_STA_GOT_IP>IP:" IPSTR, IP2STR(&event->ip_info.ip));
}

/**
 * Statically allocated pixels for the LED strip.
 */
static uint8_t led_strip_pixels[EXAMPLE_LED_NUMBERS * 3];

extern void zig_main();

/**
 * Application main function.
 */
void app_main(void) {
    setup_gpios();

    rmt_channel_handle_t led_chan = NULL;
    rmt_encoder_handle_t led_encoder = NULL;
    setup_rmt(&led_chan, &led_encoder);

    ESP_LOGI(TAG, "Start LED rainbow chase");
    rmt_transmit_config_t tx_config = {
        .loop_count = 0, // no transfer loop
    };

    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    nvs_handle flashcfg_handle;
    ESP_ERROR_CHECK(nvs_open("config", NVS_READONLY, &flashcfg_handle));

    ESP_ERROR_CHECK(esp_netif_init());

    ESP_ERROR_CHECK(esp_event_loop_create_default());

    wifi_init_config_t config = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&config));

    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &ip_event_handler, NULL));

    ESP_ERROR_CHECK(esp_netif_create_default_wifi_mesh_netifs(&netif_sta, NULL));

    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_FLASH));
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_ERROR_CHECK(esp_mesh_init());
    ESP_ERROR_CHECK(esp_mesh_set_topology(MESH_TOPO_TREE));
    ESP_ERROR_CHECK(esp_mesh_set_vote_percentage(1));
    ESP_ERROR_CHECK(esp_mesh_set_xon_qsize(128));
    ESP_ERROR_CHECK(esp_event_handler_register(MESH_EVENT, ESP_EVENT_ANY_ID, &mesh_event_handler, NULL));

    mesh_cfg_t cfg = MESH_INIT_CONFIG_DEFAULT();
    memcpy((uint8_t *) &cfg.mesh_id, MESH_ID, 6);

    ESP_ERROR_CHECK(nvs_get_u8(flashcfg_handle, "router_channel", &cfg.channel));

    cfg.router.ssid_len = 32;
    ESP_ERROR_CHECK(nvs_get_str(flashcfg_handle, "router_ssid", (char*)&cfg.router.ssid, (size_t*)&cfg.router.ssid_len));

    router_ssid = malloc(cfg.router.ssid_len);
    strncpy(router_ssid, (char*)cfg.router.ssid, cfg.router.ssid_len);

    size_t router_passwd_len = 64;
    ESP_ERROR_CHECK(nvs_get_str(flashcfg_handle, "router_passwd", (char*)&cfg.router.password, &router_passwd_len));

    router_passwd = malloc(router_passwd_len);
    strncpy(router_passwd, (char*)cfg.router.password, router_passwd_len);

    cfg.mesh_ap.max_connection = CONFIG_MESH_AP_CONNECTIONS;

    size_t ap_passwd_len = 64;
    ESP_ERROR_CHECK(nvs_get_str(flashcfg_handle, "ap_passwd", (char*)&cfg.mesh_ap.password, &ap_passwd_len));

    ap_passwd = malloc(ap_passwd_len);
    strncpy(ap_passwd, (char*)cfg.mesh_ap.password, ap_passwd_len);

    nvs_close(flashcfg_handle);

    ESP_ERROR_CHECK(esp_mesh_set_config(&cfg));

    ESP_ERROR_CHECK(esp_mesh_start());

    zig_main();

    float offset = 0;
    while (true) {
        for (int led = 0; led < EXAMPLE_LED_NUMBERS; led++) {
            // Build RGB pixels. Each color is an offset sine, which gives a
            // hue-like effect.
            float angle = offset + (led * EXAMPLE_ANGLE_INC_LED);
            const float color_off = (M_PI * 2) / 3;
            led_strip_pixels[led * 3 + 0] = sin(angle + color_off * 0) * 127 + 128;
            led_strip_pixels[led * 3 + 1] = sin(angle + color_off * 1) * 127 + 128;
            led_strip_pixels[led * 3 + 2] = sin(angle + color_off * 2) * 117 + 128;
        }
        // Flush RGB values to LEDs
        ESP_ERROR_CHECK(rmt_transmit(led_chan, led_encoder, led_strip_pixels, sizeof(led_strip_pixels), &tx_config));
        ESP_ERROR_CHECK(rmt_tx_wait_all_done(led_chan, portMAX_DELAY));
        vTaskDelay(pdMS_TO_TICKS(EXAMPLE_FRAME_DURATION_MS));
        //Increase offset to shift pattern
        offset += EXAMPLE_ANGLE_INC_FRAME;
        if (offset > 2 * M_PI) {
            offset -= 2 * M_PI;
        }
    }
}
