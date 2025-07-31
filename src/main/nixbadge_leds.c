#include "nixbadge_leds.h"

#include <math.h>

#include "driver/gpio.h"
#include "driver/rmt_tx.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "led_strip_encoder.h"

#ifdef CONFIG_BADGE_HW_REV_0_5
#define GPIO_INPUT_PIN 15
#else
#error "HW rev not supported"
#endif

#define GPIO_INPUT_PIN_SEL (1ULL << GPIO_INPUT_PIN)

#ifdef CONFIG_BADGE_HW_REV_0_5
#define GPIO_OUTPUT_PIN 23
#else
#error "HW rev not supported"
#endif

#define GPIO_OUTPUT_PIN_SEL (1ULL << GPIO_OUTPUT_PIN)

#define RMT_LED_STRIP_RESOLUTION_HZ \
  10000000  // 10MHz resolution, 1 tick = 0.1us (led strip needs a high
            // resolution)
#define RMT_LED_STRIP_GPIO_NUM 14

#define EXAMPLE_LED_NUMBERS 12
#define EXAMPLE_ANGLE_INC_LED 0.3

static const char TAG[] = "nixbadge_leds";
static uint8_t led_strip_pixels[EXAMPLE_LED_NUMBERS * 3];
static QueueHandle_t gpio_evt_queue = NULL;
static rmt_channel_handle_t led_chan = NULL;
static rmt_encoder_handle_t led_encoder = NULL;
static rmt_transmit_config_t tx_config = {
    .loop_count = 0,  // no transfer loop
};

/* Zig functions */

extern void nixbadge_leds_config_gpios();

/* C functions */

/**
 * GPIO interrupt handler. Just takes the GPIO that was signaled
 * and queues it.
 * @param arg the GPIO number
 */
static void IRAM_ATTR gpio_isr_handler(void *arg) {
  uint32_t gpio_num = (uint32_t)arg;
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
      ESP_LOGI(TAG, "GPIO[%" PRIu32 "] intr, val: %d", io_num,
               gpio_get_level(io_num));
      gpio_set_level(GPIO_OUTPUT_PIN, cnt++ % 2);
    }
  }
}

void nixbadge_leds_setup_gpios() {
  ESP_LOGI(TAG, "Setting up gpios...");
  nixbadge_leds_config_gpios();

  gpio_evt_queue = xQueueCreate(10, sizeof(uint32_t));
  xTaskCreate(gpio_task, "gpio_task", 2048, NULL, 10, NULL);
  gpio_isr_handler_add(GPIO_INPUT_PIN, gpio_isr_handler,
                       (void *)GPIO_INPUT_PIN);
}

void nixbadge_leds_setup_rmt() {
  ESP_LOGI(TAG, "Create RMT TX channel");
  rmt_tx_channel_config_t tx_chan_config = {
      .clk_src = RMT_CLK_SRC_DEFAULT,  // select source clock
      .gpio_num = RMT_LED_STRIP_GPIO_NUM,
      .mem_block_symbols =
          64,  // increase the block size can make the LED less flickering
      .resolution_hz = RMT_LED_STRIP_RESOLUTION_HZ,
      .trans_queue_depth = 4,  // set the number of transactions that can be
                               // pending in the background
  };
  ESP_ERROR_CHECK(rmt_new_tx_channel(&tx_chan_config, &led_chan));

  ESP_LOGI(TAG, "Install led strip encoder");

  led_strip_encoder_config_t encoder_config = {
      .resolution = RMT_LED_STRIP_RESOLUTION_HZ,
  };
  ESP_ERROR_CHECK(rmt_new_led_strip_encoder(&encoder_config, &led_encoder));

  ESP_LOGI(TAG, "Enable RMT TX channel");
  ESP_ERROR_CHECK(rmt_enable(led_chan));
}

void nixbadge_leds_init() {
  nixbadge_leds_setup_gpios();
  nixbadge_leds_setup_rmt(&led_chan, &led_encoder);
}

void nixbadge_leds_pulse(float offset) {
  for (int led = 0; led < EXAMPLE_LED_NUMBERS; led++) {
    // Build RGB pixels. Each color is an offset sine, which gives a
    // hue-like effect.
    float angle = offset + (led * EXAMPLE_ANGLE_INC_LED);
    const float color_off = (M_PI * 2) / 3;
    led_strip_pixels[led * 3 + 0] = sinf(angle + color_off * 0) * 127 + 128;
    led_strip_pixels[led * 3 + 1] = sinf(angle + color_off * 1) * 127 + 128;
    led_strip_pixels[led * 3 + 2] = sinf(angle + color_off * 2) * 117 + 128;
  }

  // Flush RGB values to LEDs
  ESP_ERROR_CHECK(rmt_transmit(led_chan, led_encoder, led_strip_pixels,
                               sizeof(led_strip_pixels), &tx_config));
  ESP_ERROR_CHECK(rmt_tx_wait_all_done(led_chan, portMAX_DELAY));
}
