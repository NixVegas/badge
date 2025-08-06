#include "esp_log.h"

#ifdef CONFIG_BADGE_HW_REV_0_5
#define GPIO_INPUT_PIN 15
#else
#ifdef CONFIG_BADGE_HW_REV_1_0
#define GPIO_INPUT_PIN 3
#else
#error "HW rev not supported"
#endif
#endif

#ifdef CONFIG_BADGE_HW_REV_0_5
#define GPIO_OUTPUT_PIN 23
#else
#ifdef CONFIG_BADGE_HW_REV_1_0
#define GPIO_OUTPUT_PIN 15
#else
#error "HW rev not supported"
#endif
#endif

#define RMT_LED_STRIP_GPIO_NUM 14

#ifdef CONFIG_BADGE_HW_REV_1_0
#define GPIO_SDET_PIN 8
#define GPIO_VSEL2 2
#endif
