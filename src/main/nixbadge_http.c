#include "nixbadge_http.h"
#include "nixbadge_mesh.h"

#include <esp_mesh_lite.h>
#include <esp_http_client.h>
#include <esp_http_server.h>
#include <esp_log.h>
#include <esp_tls.h>
#include <nvs_flash.h>
#include <string.h>

static const char TAG[] = "nixbadge_http";

static esp_err_t http_client_get_serve(esp_http_client_event_t* evt) {
  httpd_req_t* req = evt->user_data;
  switch (evt->event_id) {
    case HTTP_EVENT_ERROR:
      ESP_LOGI(TAG, "Received error while fetching %s", req->uri);
      break;
    case HTTP_EVENT_ON_CONNECTED:
      ESP_LOGI(TAG, "Connected to upstream cache at %s", req->uri);
      break;
    case HTTP_EVENT_ON_HEADER:
      ESP_LOGI(TAG, "Received header \"%s: %s\" for %s", evt->header_key,
               evt->header_value, req->uri);
      httpd_resp_set_hdr(req, evt->header_key, evt->header_value);
      break;
    case HTTP_EVENT_ON_DATA:
      ESP_LOGI(TAG, "Received chunk %d for %s", evt->data_len, req->uri);
      return httpd_resp_send_chunk(req, evt->data, evt->data_len);
    case HTTP_EVENT_ON_FINISH:
      ESP_LOGI(TAG, "Connection to upstream cache at %s is complete", req->uri);
      httpd_resp_sendstr_chunk(req, NULL);
      break;
    case HTTP_EVENT_DISCONNECTED: {
      ESP_LOGI(TAG, "Got disconnected while fetching %s", req->uri);
      int mbedtls_err = 0;
      esp_err_t err = esp_tls_get_and_clear_last_error(
          (esp_tls_error_handle_t)evt->data, &mbedtls_err, NULL);
      if (err != 0) {
        ESP_LOGI(TAG, "Last esp error code: 0x%x", err);
        ESP_LOGI(TAG, "Last mbedtls failure: 0x%x", mbedtls_err);
      }
    } break;
    default:
      break;
  }
  return ESP_OK;
}

static char* get_cache_host() {
  if (esp_mesh_lite_get_level() == ROOT) {
    nvs_handle flashcfg_handle;
    ESP_ERROR_CHECK(nvs_open("config", NVS_READONLY, &flashcfg_handle));

    size_t cache_store_len;
    ESP_ERROR_CHECK(
      nvs_get_str(flashcfg_handle, "cache_upstream", NULL, &cache_store_len));

    char* cache_store = malloc(cache_store_len);
    ESP_ERROR_CHECK(nvs_get_str(flashcfg_handle, "cache_upstream", cache_store,
                              &cache_store_len));
    return cache_store;
  } else {
    esp_ip4_addr_t addr = nixbadge_mesh_get_gateway();
    char* str = NULL;
    asprintf(&str, IPSTR, IP2STR(&addr));
    return str;
  }
}

static esp_err_t nix_cache_info_get_handler(httpd_req_t* req) {
  nvs_handle flashcfg_handle;
  ESP_ERROR_CHECK(nvs_open("config", NVS_READONLY, &flashcfg_handle));

  size_t cache_store_len;
  ESP_ERROR_CHECK(
      nvs_get_str(flashcfg_handle, "cache_store", NULL, &cache_store_len));

  char* cache_store = malloc(cache_store_len);
  ESP_ERROR_CHECK(nvs_get_str(flashcfg_handle, "cache_store", cache_store,
                              &cache_store_len));

  uint32_t cache_priority;
  ESP_ERROR_CHECK(
      nvs_get_u32(flashcfg_handle, "cache_priority", &cache_priority));

  char* value;
  int len = asprintf(&value, "StoreDir: %s\nWantMassQuery: 1\nPriority: %lu\n",
                     cache_store, cache_priority);

  httpd_resp_set_hdr(req, "Content-Type", "text/x-nix-cache-info");
  esp_err_t err = httpd_resp_send(req, value, len);

  nvs_close(flashcfg_handle);
  free(value);
  return err;
}

static esp_err_t narinfo_get_handler(httpd_req_t* req) {
  char* cache_host = get_cache_host();

  nvs_handle flashcfg_handle;
  ESP_ERROR_CHECK(nvs_open("config", NVS_READONLY, &flashcfg_handle));

  ESP_LOGI(TAG, "Querying %s on level %d", req->uri, esp_mesh_lite_get_level());

  esp_http_client_config_t config = {
      .host = cache_host,
      .path = req->uri,
      .event_handler = http_client_get_serve,
      .user_data = req,
      .buffer_size = 16 * 1024,
      .is_async = false,
      .timeout_ms = 3000000,
  };

  uint8_t cache_use_https = 0;
  ESP_ERROR_CHECK(
      nvs_get_u8(flashcfg_handle, "cache_use_https", &cache_use_https));

  if (cache_use_https && esp_mesh_lite_get_level() == ROOT) {
    config.transport_type = HTTP_TRANSPORT_OVER_SSL;

    size_t cache_cert_len;
    esp_err_t err =
        nvs_get_str(flashcfg_handle, "cache_cert", NULL, &cache_cert_len);
    if (err != ESP_ERR_NVS_NOT_FOUND) {
      ESP_ERROR_CHECK(err);

      char* cache_cert = malloc(cache_cert_len + 1);

      ESP_ERROR_CHECK(nvs_get_str(flashcfg_handle, "cache_cert", cache_cert,
                                  &cache_cert_len));
      cache_cert[cache_cert_len] = 0;

      config.cert_pem = cache_cert;
      config.cert_len = cache_cert_len;
    } else {
      config.use_global_ca_store = true;
    }
  } else if (esp_mesh_lite_get_level() != ROOT) {
    config.port = 1008;
  }

  httpd_resp_set_hdr(req, "Content-Type", "text/x-nix-narinfo");

  esp_http_client_handle_t client = esp_http_client_init(&config);
  esp_err_t err = esp_http_client_perform(client);

  free(cache_host);
  nvs_close(flashcfg_handle);

  if (config.cert_pem) free((void*)config.cert_pem);
  esp_http_client_cleanup(client);
  return err;
}

static esp_err_t nar_get_handler(httpd_req_t* req) {
  char* cache_host = get_cache_host();

  nvs_handle flashcfg_handle;
  ESP_ERROR_CHECK(nvs_open("config", NVS_READONLY, &flashcfg_handle));

  ESP_LOGI(TAG, "Querying %s on level %d", req->uri, esp_mesh_lite_get_level());

  esp_http_client_config_t config = {
      .host = cache_host,
      .path = req->uri,
      .buffer_size = 64 * 1024,
      .event_handler = http_client_get_serve,
      .user_data = req,
      .is_async = false,
      .timeout_ms = 3000000,
  };

  uint8_t cache_use_https = 0;
  ESP_ERROR_CHECK(
      nvs_get_u8(flashcfg_handle, "cache_use_https", &cache_use_https));

  if (cache_use_https && esp_mesh_lite_get_level() == ROOT) {
    config.transport_type = HTTP_TRANSPORT_OVER_SSL;

    size_t cache_cert_len;
    esp_err_t err =
        nvs_get_str(flashcfg_handle, "cache_cert", NULL, &cache_cert_len);
    if (err != ESP_ERR_NVS_NOT_FOUND) {
      ESP_ERROR_CHECK(err);

      char* cache_cert = malloc(cache_cert_len + 1);

      ESP_ERROR_CHECK(nvs_get_str(flashcfg_handle, "cache_cert", cache_cert,
                                  &cache_cert_len));
      cache_cert[cache_cert_len] = 0;

      config.cert_pem = cache_cert;
      config.cert_len = cache_cert_len;
    } else {
      config.use_global_ca_store = true;
    }
  } else if (esp_mesh_lite_get_level() != ROOT) {
    config.port = 1008;
  }

  httpd_resp_set_hdr(req, "Content-Type", "application/x-nix-nar");

  esp_http_client_handle_t client = esp_http_client_init(&config);
  esp_err_t err = esp_http_client_perform(client);

  free(cache_host);
  nvs_close(flashcfg_handle);

  if (config.cert_pem) free((void*)config.cert_pem);
  esp_http_client_cleanup(client);
  return err;
}

static const httpd_uri_t nix_cache_info = {
    .uri = "/nix-cache-info",
    .method = HTTP_GET,
    .handler = nix_cache_info_get_handler,
};

static const httpd_uri_t nar = {
    .uri = "/nar/*",
    .method = HTTP_GET,
    .handler = nar_get_handler,
};

static const httpd_uri_t narinfo = {
    .uri = "/*",
    .method = HTTP_GET,
    .handler = narinfo_get_handler,
};

void nixbadge_http_init() {
  ESP_ERROR_CHECK(esp_tls_init_global_ca_store());

  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 1008;
  config.uri_match_fn = httpd_uri_match_wildcard;
  httpd_handle_t server = NULL;

  ESP_ERROR_CHECK(httpd_start(&server, &config));

  httpd_register_uri_handler(server, &nix_cache_info);
  httpd_register_uri_handler(server, &nar);
  httpd_register_uri_handler(server, &narinfo);
}
