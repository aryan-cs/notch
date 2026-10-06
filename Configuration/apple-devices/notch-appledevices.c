/*
 * notch-appledevices.c
 * Battery levels for trusted iPhones and iPads (over USB or Wi-Fi) and the
 * Apple Watches paired to them, printed as one JSON array.
 *
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * Same data path as AirBattery's bundled tools (github.com/lihaoyun6/AirBattery),
 * in one process: the device list (idevice_id), lockdown's
 * com.apple.mobile.battery domain (ideviceinfo -q), the wireless_lockdown
 * EnableWifiConnections switch for USB devices (wificonnection) and the
 * companion proxy for watches (comptest).
 *
 * Output: [{"id","name","model","class","battery","charging","serial"?,"parent"?}, ...]
 * Devices that haven't trusted this Mac, or don't answer, are skipped.
 */

#include <libimobiledevice/companion_proxy.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <plist/plist.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *label = "boringnotch";
static int printed = 0;

static void print_json_string(const char *s) {
    putchar('"');
    for (; s && *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') printf("\\%c", c);
        else if (c < 0x20) printf("\\u%04x", c);
        else putchar(c);
    }
    putchar('"');
}

/* Battery level from a plist node: an integer, or a real on some watches. */
static int plist_level(plist_t node) {
    if (!node) return -1;
    if (plist_get_node_type(node) == PLIST_UINT) {
        uint64_t v = 0;
        plist_get_uint_val(node, &v);
        return (int)v;
    }
    if (plist_get_node_type(node) == PLIST_REAL) {
        double v = 0;
        plist_get_real_val(node, &v);
        return (int)(v + 0.5);
    }
    return -1;
}

static int plist_flag(plist_t node) {
    if (!node || plist_get_node_type(node) != PLIST_BOOLEAN) return -1;
    uint8_t v = 0;
    plist_get_bool_val(node, &v);
    return v ? 1 : 0;
}

static char *plist_string(plist_t node) {
    char *s = NULL;
    if (node && plist_get_node_type(node) == PLIST_STRING) plist_get_string_val(node, &s);
    return s;
}

static char *lockdown_string(lockdownd_client_t ld, const char *domain, const char *key) {
    plist_t node = NULL;
    char *s = NULL;
    if (lockdownd_get_value(ld, domain, key, &node) == LOCKDOWN_E_SUCCESS) s = plist_string(node);
    plist_free(node);
    return s;
}

static int lockdown_level(lockdownd_client_t ld, const char *key) {
    plist_t node = NULL;
    int v = -1;
    if (lockdownd_get_value(ld, "com.apple.mobile.battery", key, &node) == LOCKDOWN_E_SUCCESS) v = plist_level(node);
    plist_free(node);
    return v;
}

static int lockdown_flag(lockdownd_client_t ld, const char *key) {
    plist_t node = NULL;
    int v = -1;
    if (lockdownd_get_value(ld, "com.apple.mobile.battery", key, &node) == LOCKDOWN_E_SUCCESS) v = plist_flag(node);
    plist_free(node);
    return v;
}

static void emit(const char *id, const char *name, const char *model, const char *cls,
                 int battery, int charging, const char *serial, const char *parent) {
    if (battery < 0) return;
    if (printed++) putchar(',');
    printf("{\"id\":");
    print_json_string(id);
    printf(",\"name\":");
    print_json_string(name ? name : cls);
    printf(",\"model\":");
    print_json_string(model ? model : "");
    printf(",\"class\":");
    print_json_string(cls ? cls : "");
    printf(",\"battery\":%d,\"charging\":%s", battery, charging == 1 ? "true" : "false");
    /* For Find My's device links (fmip1://device/device?sn=...). */
    if (serial) {
        printf(",\"serial\":");
        print_json_string(serial);
    }
    if (parent) {
        printf(",\"parent\":");
        print_json_string(parent);
    }
    putchar('}');
}

/* Watches paired to an iPhone, read through its companion proxy. */
static void emit_watches(idevice_t device, const char *phone_name) {
    companion_proxy_client_t proxy = NULL;
    if (companion_proxy_client_start_service(device, &proxy, label) != COMPANION_PROXY_E_SUCCESS) return;

    plist_t registry = NULL;
    if (companion_proxy_get_device_registry(proxy, &registry) == COMPANION_PROXY_E_SUCCESS
        && plist_get_node_type(registry) == PLIST_ARRAY) {
        for (uint32_t i = 0; i < plist_array_get_size(registry); i++) {
            char *watch_id = plist_string(plist_array_get_item(registry, i));
            if (!watch_id) continue;

            plist_t name_node = NULL, model_node = NULL, level_node = NULL, charging_node = NULL, serial_node = NULL;
            companion_proxy_get_value_from_registry(proxy, watch_id, "DeviceName", &name_node);
            companion_proxy_get_value_from_registry(proxy, watch_id, "ProductType", &model_node);
            companion_proxy_get_value_from_registry(proxy, watch_id, "BatteryCurrentCapacity", &level_node);
            companion_proxy_get_value_from_registry(proxy, watch_id, "BatteryIsCharging", &charging_node);
            companion_proxy_get_value_from_registry(proxy, watch_id, "SerialNumber", &serial_node);

            char *name = plist_string(name_node);
            char *model = plist_string(model_node);
            char *serial = plist_string(serial_node);
            emit(watch_id, name, model, "Watch", plist_level(level_node), plist_flag(charging_node), serial, phone_name);

            free(name);
            free(model);
            free(serial);
            plist_free(name_node);
            plist_free(model_node);
            plist_free(serial_node);
            plist_free(level_node);
            plist_free(charging_node);
            free(watch_id);
        }
    }
    plist_free(registry);
    companion_proxy_client_free(proxy);
}

static void read_device(const char *udid, enum idevice_connection_type connection) {
    idevice_t device = NULL;
    enum idevice_options lookup = connection == CONNECTION_NETWORK ? IDEVICE_LOOKUP_NETWORK : IDEVICE_LOOKUP_USBMUX;
    if (idevice_new_with_options(&device, udid, lookup) != IDEVICE_E_SUCCESS) return;

    lockdownd_client_t lockdown = NULL;
    if (lockdownd_client_new_with_handshake(device, &lockdown, label) != LOCKDOWN_E_SUCCESS) {
        idevice_free(device);
        return;
    }

    char *name = lockdown_string(lockdown, NULL, "DeviceName");
    char *model = lockdown_string(lockdown, NULL, "ProductType");
    char *cls = lockdown_string(lockdown, NULL, "DeviceClass");
    char *serial = lockdown_string(lockdown, NULL, "SerialNumber");
    int battery = lockdown_level(lockdown, "BatteryCurrentCapacity");
    int charging = lockdown_flag(lockdown, "BatteryIsCharging");

    /* What Finder's "Show this iPhone when on Wi-Fi" sets: lets later reads
       work over the network without the cable. lockdownd_set_value takes
       ownership of the value. */
    if (connection == CONNECTION_USBMUXD) {
        lockdownd_set_value(lockdown, "com.apple.mobile.wireless_lockdown", "EnableWifiConnections", plist_new_bool(1));
    }
    lockdownd_client_free(lockdown);

    emit(udid, name, model, cls, battery, charging, serial, NULL);
    if (cls && strcmp(cls, "iPhone") == 0) emit_watches(device, name);

    free(name);
    free(model);
    free(cls);
    free(serial);
    idevice_free(device);
}

int main(void) {
    /* An unreachable device can stall a network connection; never hang the caller. */
    alarm(25);

    idevice_info_t *devices = NULL;
    int count = 0;
    printf("[");
    if (idevice_get_device_list_extended(&devices, &count) == IDEVICE_E_SUCCESS) {
        /* A device can be listed on both USB and Wi-Fi: read it once, USB first. */
        char **seen = calloc((size_t)count + 1, sizeof(char *));
        int seen_count = 0;
        for (int pass = 0; pass < 2; pass++) {
            enum idevice_connection_type wanted = pass == 0 ? CONNECTION_USBMUXD : CONNECTION_NETWORK;
            for (int i = 0; i < count; i++) {
                if (devices[i]->conn_type != wanted) continue;
                int duplicate = 0;
                for (int j = 0; j < seen_count; j++) {
                    if (strcmp(seen[j], devices[i]->udid) == 0) duplicate = 1;
                }
                if (duplicate) continue;
                seen[seen_count++] = devices[i]->udid;
                read_device(devices[i]->udid, wanted);
            }
        }
        free(seen);
        idevice_device_list_extended_free(devices);
    }
    printf("]\n");
    return 0;
}
