/*
 * nixbadge
 * Nix Vegas - Rebuild the world!
 */

#include <string.h>
#include <math.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"

#include "esp_log.h"
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

/**
 * Log tag.
 */
static const char TAG[] = "nixbadge";

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
