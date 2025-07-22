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

static const uint8_t MESH_ID[6] = { 0x77, 0x77, 0x77, 0x77, 0x77, 0x77};

#define CONFIG_MESH_AP_CONNECTIONS 10

static mesh_addr_t mesh_parent_addr;
static int mesh_layer = -1;
static esp_netif_t *netif_sta = NULL;

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

void mesh_connected_indicator(int i) {
  ESP_LOGI(TAG, "Mesh connected %d", i);
}

void mesh_scan_done_handler(int num)
{
    int i;
    int ie_len = 0;
    mesh_assoc_t assoc;
    mesh_assoc_t parent_assoc = { .layer = 6, .rssi = -120 };
    wifi_ap_record_t record;
    wifi_ap_record_t parent_record = { 0, };
    bool parent_found = false;
    mesh_type_t my_type = MESH_IDLE;
    int my_layer = -1;
    wifi_config_t parent = { 0, };
    wifi_scan_config_t scan_config = { 0 };

    for (i = 0; i < num; i++) {
        esp_mesh_scan_get_ap_ie_len(&ie_len);
        esp_mesh_scan_get_ap_record(&record, &assoc);
        if (ie_len == sizeof(assoc)) {
            ESP_LOGW(MESH_TAG,
                     "<MESH>[%d]%s, layer:%d/%d, assoc:%d/%d, %d, "MACSTR", channel:%u, rssi:%d, ID<"MACSTR"><%s>",
                     i, record.ssid, assoc.layer, assoc.layer_cap, assoc.assoc,
                     assoc.assoc_cap, assoc.layer2_cap, MAC2STR(record.bssid),
                     record.primary, record.rssi, MAC2STR(assoc.mesh_id), assoc.encrypted ? "IE Encrypted" : "IE Unencrypted");

#if CONFIG_MESH_SET_NODE
            if (assoc.mesh_type != MESH_IDLE && assoc.layer_cap
                    && assoc.assoc < assoc.assoc_cap && record.rssi > -70) {
                if (assoc.layer < parent_assoc.layer || assoc.layer2_cap < parent_assoc.layer2_cap) {
                    parent_found = true;
                    memcpy(&parent_record, &record, sizeof(record));
                    memcpy(&parent_assoc, &assoc, sizeof(assoc));
                    if (parent_assoc.layer_cap != 1) {
                        my_type = MESH_NODE;
                    } else {
                        my_type = MESH_LEAF;
                    }
                    my_layer = parent_assoc.layer + 1;
                    break;
                }
            }
#endif
        } else {
            ESP_LOGI(MESH_TAG, "[%d]%s, "MACSTR", channel:%u, rssi:%d", i,
                     record.ssid, MAC2STR(record.bssid), record.primary,
                     record.rssi);
#if CONFIG_MESH_SET_ROOT
            if (!strcmp(CONFIG_MESH_ROUTER_SSID, (char *) record.ssid)) {
                parent_found = true;
                memcpy(&parent_record, &record, sizeof(record));
                my_type = MESH_ROOT;
                my_layer = MESH_ROOT_LAYER;
            }
#endif
        }
    }
    esp_mesh_flush_scan_result();
    if (parent_found) {
        /*
         * parent
         * Both channel and SSID of the parent are mandatory.
         */
        parent.sta.channel = parent_record.primary;
        memcpy(&parent.sta.ssid, &parent_record.ssid,
               sizeof(parent_record.ssid));
        parent.sta.bssid_set = 1;
        memcpy(&parent.sta.bssid, parent_record.bssid, 6);
        if (my_type == MESH_ROOT) {
            if (parent_record.authmode != WIFI_AUTH_OPEN) {
                memcpy(&parent.sta.password, router_passwd,
                       strlen(router_passwd));
            }
            ESP_LOGW(MESH_TAG, "<PARENT>%s, "MACSTR", channel:%u, rssi:%d",
                     parent_record.ssid, MAC2STR(parent_record.bssid),
                     parent_record.primary, parent_record.rssi);
            ESP_ERROR_CHECK(esp_mesh_set_parent(&parent, NULL, my_type, my_layer));
        } else {
            ESP_ERROR_CHECK(esp_mesh_set_ap_authmode(parent_record.authmode));
            if (parent_record.authmode != WIFI_AUTH_OPEN) {
                memcpy(&parent.sta.password, ap_passwd,
                       strlen(ap_passwd));
            }
            ESP_LOGW(MESH_TAG,
                     "<PARENT>%s, layer:%d/%d, assoc:%d/%d, %d, "MACSTR", channel:%u, rssi:%d",
                     parent_record.ssid, parent_assoc.layer,
                     parent_assoc.layer_cap, parent_assoc.assoc,
                     parent_assoc.assoc_cap, parent_assoc.layer2_cap,
                     MAC2STR(parent_record.bssid), parent_record.primary,
                     parent_record.rssi);
            ESP_ERROR_CHECK(esp_mesh_set_parent(&parent, (mesh_addr_t *)&parent_assoc.mesh_id, my_type, my_layer));
        }

    } else {
        esp_wifi_scan_stop();
        scan_config.show_hidden = 1;
        scan_config.scan_type = WIFI_SCAN_TYPE_PASSIVE;
        esp_wifi_scan_start(&scan_config, 0);
    }
}

void mesh_event_handler(void *arg, esp_event_base_t event_base,
                        int32_t event_id, void *event_data)
{
    mesh_addr_t id = {0,};
    static int last_layer = 0;
    wifi_scan_config_t scan_config = { 0 };

    switch (event_id) {
    case MESH_EVENT_STARTED: {
        esp_mesh_get_id(&id);
        ESP_LOGI(MESH_TAG, "<MESH_EVENT_STARTED>ID:"MACSTR"", MAC2STR(id.addr));
        mesh_layer = esp_mesh_get_layer();
        ESP_ERROR_CHECK(esp_mesh_set_self_organized(1, 1));
        esp_wifi_scan_stop();
        /* mesh softAP is hidden */
        scan_config.show_hidden = 1;
        scan_config.scan_type = WIFI_SCAN_TYPE_PASSIVE;
        esp_wifi_scan_start(&scan_config, 0);
    }
    break;
    case MESH_EVENT_STOPPED: {
        ESP_LOGI(MESH_TAG, "<MESH_EVENT_STOPPED>");
        mesh_layer = esp_mesh_get_layer();
    }
    break;
    case MESH_EVENT_CHILD_CONNECTED: {
        mesh_event_child_connected_t *child_connected = (mesh_event_child_connected_t *)event_data;
        ESP_LOGI(MESH_TAG, "<MESH_EVENT_CHILD_CONNECTED>aid:%d, "MACSTR"",
                 child_connected->aid,
                 MAC2STR(child_connected->mac));
    }
    break;
    case MESH_EVENT_CHILD_DISCONNECTED: {
        mesh_event_child_disconnected_t *child_disconnected = (mesh_event_child_disconnected_t *)event_data;
        ESP_LOGI(MESH_TAG, "<MESH_EVENT_CHILD_DISCONNECTED>aid:%d, "MACSTR"",
                 child_disconnected->aid,
                 MAC2STR(child_disconnected->mac));
    }
    break;
    case MESH_EVENT_ROUTING_TABLE_ADD: {
        mesh_event_routing_table_change_t *routing_table = (mesh_event_routing_table_change_t *)event_data;
        ESP_LOGW(MESH_TAG, "<MESH_EVENT_ROUTING_TABLE_ADD>add %d, new:%d",
                 routing_table->rt_size_change,
                 routing_table->rt_size_new);
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
        mesh_connected_indicator(mesh_layer);
        if (esp_mesh_is_root()) {
            esp_netif_dhcpc_stop(netif_sta);
            esp_netif_dhcpc_start(netif_sta);
        }
    }
    break;
    case MESH_EVENT_PARENT_DISCONNECTED: {
        mesh_event_disconnected_t *disconnected = (mesh_event_disconnected_t *)event_data;
        ESP_LOGI(MESH_TAG,
                 "<MESH_EVENT_PARENT_DISCONNECTED>reason:%d",
                 disconnected->reason);
        //mesh_disconnected_indicator();
        mesh_layer = esp_mesh_get_layer();
        if (disconnected->reason == WIFI_REASON_ASSOC_TOOMANY) {
            esp_wifi_scan_stop();
            scan_config.show_hidden = 1;
            scan_config.scan_type = WIFI_SCAN_TYPE_PASSIVE;
            esp_wifi_scan_start(&scan_config, 0);
        }
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

    ESP_ERROR_CHECK(nvs_flash_init());

    nvs_handle flashcfg_handle;
    ESP_ERROR_CHECK(nvs_open("config", NVS_READONLY, &flashcfg_handle));

    ESP_ERROR_CHECK(esp_netif_init());

    ESP_ERROR_CHECK(esp_event_loop_create_default());

    wifi_init_config_t config = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&config));

    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &ip_event_handler, NULL));

    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_FLASH));
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_ERROR_CHECK(esp_mesh_init());
    ESP_ERROR_CHECK(esp_event_handler_register(MESH_EVENT, ESP_EVENT_ANY_ID, &mesh_event_handler, NULL));

    mesh_cfg_t cfg = MESH_INIT_CONFIG_DEFAULT();
    memcpy((uint8_t *) &cfg.mesh_id, MESH_ID, 6);

    ESP_ERROR_CHECK(nvs_get_u8(flashcfg_handle, "router_channel", &cfg.channel));

    ESP_ERROR_CHECK(nvs_get_str(flashcfg_handle, "router_ssid", (char*)&cfg.router.ssid, (size_t*)&cfg.router.ssid_len));

    size_t router_passwd_len = 0;
    ESP_ERROR_CHECK(nvs_get_str(flashcfg_handle, "router_passwd", (char*)&cfg.router.password, &router_passwd_len));

    router_passwd = malloc(router_passwd_len);
    strncpy(router_passwd, (char*)cfg.router.password, router_passwd_len);

    cfg.mesh_ap.max_connection = CONFIG_MESH_AP_CONNECTIONS;

    size_t ap_passwd_len = 0;
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
