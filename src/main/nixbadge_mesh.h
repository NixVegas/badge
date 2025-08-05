#pragma once

#include "esp_wifi.h"
#include "esp_mesh.h"

esp_err_t nixbadge_mesh_broadcast(uint8_t kind);
esp_ip4_addr_t nixbadge_mesh_get_gateway();
float nixbadge_mesh_ping_measure(uint8_t);

bool nixbadge_has_mesh();
void nixbadge_mesh_init();
