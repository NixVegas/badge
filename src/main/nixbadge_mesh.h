#pragma once

#include "esp_wifi.h"
#include "esp_mesh.h"

esp_err_t nixbadge_mesh_send_packet(const mesh_addr_t* to, uint8_t kind);
esp_err_t nixbadge_mesh_recv_packet(int timeout_ms);
esp_ip4_addr_t nixbadge_mesh_get_gateway();
float nixbadge_mesh_avg_ping();

void nixbadge_mesh_init();
