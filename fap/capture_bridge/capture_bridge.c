/**
 * Capture Bridge - device-side companion for the FlipperHero fork.
 *
 * Why this exists: the Flipper's protobuf RPC has no RF messages (only system, storage, app,
 * gui, gpio, property, desktop), so "press a button on the phone and capture the remote"
 * cannot be done by the phone alone. This app runs on the Flipper, drives the radio, and
 * talks to the phone over the RPC app-data-exchange channel.
 *
 * Protocol - one command per exchange, newline terminated, plain ASCII:
 *   ping                  -> "pong"
 *   status                -> "idle" | "capturing <freq_hz>" | "done <result>"
 *   rx <freq_hz> [ms]     -> "started"  (capture runs on a worker thread)
 *   result                -> the last result line, e.g. "ok /ext/subghz/cap_x.sub pairs=812"
 *   quit                  -> the app exits
 *   anything else         -> "err unknown <cmd>"
 * When a capture finishes the app also pushes "done <result>" unprompted.
 *
 * Standalone (no phone) it shows the same status on screen: OK captures 3 s on 433.92 MHz,
 * Back exits.
 *
 * Capture settings are deliberately dumb for v0.1: OOK 650 kHz async preset, raw level
 * durations, written as a Flipper Sub-GHz RAW file. Trimming the burst and protocol
 * decoding are left to the Sub-GHz app on the device.
 */
#include <furi.h>
#include <furi_hal.h>

#include <gui/gui.h>
#include <gui/canvas.h>
#include <input/input.h>
#include <storage/storage.h>
#include <rpc/rpc_app.h>

#include <subghz/subghz_worker.h>
#include <subghz/devices/devices.h>
#include <subghz/devices/preset.h>
#include <subghz/devices/cc1101_int/cc1101_int_interconnect.h>

#define TAG "CaptureBridge"

#define MAX_PAIRS         4096
#define DEFAULT_FREQ_HZ   433920000UL
#define DEFAULT_WINDOW_MS 3000UL
#define CAPTURE_DIR       "/ext/subghz"
#define RESULT_LEN        96
#define CMD_LEN           64
#define WORKER_STACK      4096

typedef struct {
    bool rpc_mode;
    volatile bool exit_requested;
    volatile bool capturing;
    volatile uint32_t pair_count;
    int32_t pairs[MAX_PAIRS];
    char pending_cmd[CMD_LEN];
    char result[RESULT_LEN];

    FuriMutex* state_mutex;
    FuriSemaphore* cmd_sem;
    FuriThread* worker;
    SubGhzWorker* rx_worker;

    RpcAppSystem* rpc;
    Gui* gui;
    ViewPort* view_port;
    FuriMessageQueue* input_queue;
} CaptureBridgeApp;

/* ---------------------------------------------------------------- capture --- */

static void bridge_pair_callback(void* context, bool level, uint32_t duration) {
    CaptureBridgeApp* app = context;
    if(duration == 0) return;
    uint32_t index = app->pair_count;
    if(index >= MAX_PAIRS) return;
    /* Sign encodes the level: positive = high, negative = low. That is the RAW file format. */
    app->pairs[index] = level ? (int32_t)duration : -(int32_t)duration;
    app->pair_count = index + 1;
}

static void bridge_overrun_callback(void* context) {
    UNUSED(context);
}

static void bridge_set_result(CaptureBridgeApp* app, const char* text) {
    furi_mutex_acquire(app->state_mutex, FURI_TIMEOUT_RELAXED);
    snprintf(app->result, sizeof(app->result), "%s", text);
    furi_mutex_release(app->state_mutex);
}

static bool bridge_write_raw(CaptureBridgeApp* app, uint32_t freq_hz, char* path_out, size_t path_len) {
    Storage* storage = furi_record_open(RECORD_STORAGE);
    storage_common_mkdir(storage, CAPTURE_DIR);

    DateTime dt;
    furi_hal_rtc_get_datetime(&dt);
    snprintf(
        path_out,
        path_len,
        CAPTURE_DIR "/cap_%04u%02u%02u-%02u%02u%02u.sub",
        (unsigned)dt.year,
        (unsigned)dt.month,
        (unsigned)dt.day,
        (unsigned)dt.hour,
        (unsigned)dt.minute,
        (unsigned)dt.second);

    bool ok = false;
    File* file = storage_file_alloc(storage);
    if(storage_file_open(file, path_out, FSAM_WRITE, FSOM_CREATE_ALWAYS)) {
        FuriString* line = furi_string_alloc();
        furi_string_printf(
            line,
            "Filetype: Flipper SubGhz RAW File\n"
            "Version: 1\n"
            "Frequency: %lu\n"
            "Preset: FuriHalSubGhzPresetOok650Async\n"
            "Protocol: RAW\n",
            (unsigned long)freq_hz);
        (void)storage_file_write(file, furi_string_get_cstr(line), furi_string_size(line));

        furi_string_set_str(line, "RAW_Data:");
        for(uint32_t i = 0; i < app->pair_count; i++) {
            furi_string_cat_printf(line, " %ld", (long)app->pairs[i]);
            if(i % 128 == 127 && i + 1 < app->pair_count) {
                furi_string_push_back(line, '\n');
                (void)storage_file_write(file, furi_string_get_cstr(line), furi_string_size(line));
                furi_string_set_str(line, "RAW_Data:");
            }
        }
        furi_string_push_back(line, '\n');
        (void)storage_file_write(file, furi_string_get_cstr(line), furi_string_size(line));
        furi_string_free(line);
        storage_file_close(file);
        ok = true;
    }
    storage_file_free(file);
    furi_record_close(RECORD_STORAGE);
    return ok;
}

static void bridge_capture(CaptureBridgeApp* app, uint32_t freq_hz, uint32_t window_ms) {
    char result[RESULT_LEN];
    char path[96];
    bool device_up = false;

    app->pair_count = 0;
    app->capturing = true;
    bridge_set_result(app, "capturing");
    if(app->view_port) view_port_update(app->view_port);

    const SubGhzDevice* device = subghz_devices_get_by_name(SUBGHZ_DEVICE_CC1101_INT_NAME);
    if(!device) {
        snprintf(result, sizeof(result), "err no radio");
    } else if(!subghz_devices_begin(device)) {
        snprintf(result, sizeof(result), "err radio busy");
    } else {
        device_up = true;
        subghz_devices_reset(device);
        subghz_devices_load_preset(device, FuriHalSubGhzPresetOok650Async, NULL);
        uint32_t real_freq = subghz_devices_set_frequency(device, freq_hz);
        subghz_devices_flush_rx(device);

        subghz_worker_start(app->rx_worker);
        uint32_t waited = 0;
        while(waited < window_ms && !app->exit_requested) {
            furi_delay_ms(20);
            waited += 20;
        }
        subghz_worker_stop(app->rx_worker);
        subghz_devices_idle(device);
        subghz_devices_end(device);
        device_up = false;

        uint32_t pairs = app->pair_count;
        if(pairs == 0) {
            snprintf(result, sizeof(result), "err no signal %lu pairs=0", (unsigned long)real_freq);
        } else if(bridge_write_raw(app, real_freq, path, sizeof(path))) {
            snprintf(result, sizeof(result), "ok %s pairs=%lu", path, (unsigned long)pairs);
        } else {
            snprintf(result, sizeof(result), "err write failed pairs=%lu", (unsigned long)pairs);
        }
    }

    if(device_up) subghz_devices_end(device);
    app->capturing = false;
    bridge_set_result(app, result);
    if(app->view_port) view_port_update(app->view_port);
    if(app->rpc) {
        FuriString* push = furi_string_alloc_printf("done %s\n", result);
        rpc_system_app_exchange_data(app->rpc, (const uint8_t*)furi_string_get_cstr(push), furi_string_size(push));
        furi_string_free(push);
    }
    FURI_LOG_I(TAG, "capture: %s", result);
}

static int32_t bridge_worker_thread(void* context) {
    CaptureBridgeApp* app = context;
    while(!app->exit_requested) {
        if(furi_semaphore_acquire(app->cmd_sem, FURI_SEMAPHORE_WAIT_FOREVER) != FuriStatusOk) continue;
        if(app->exit_requested) break;

        char cmd[CMD_LEN];
        furi_mutex_acquire(app->state_mutex, FURI_TIMEOUT_RELAXED);
        snprintf(cmd, sizeof(cmd), "%s", app->pending_cmd);
        furi_mutex_release(app->state_mutex);

        unsigned long freq = 0;
        unsigned long window = 0;
        if(sscanf(cmd, "rx %lu %lu", &freq, &window) >= 1) {
            bridge_capture(
                app,
                freq ? (uint32_t)freq : DEFAULT_FREQ_HZ,
                window ? (uint32_t)window : DEFAULT_WINDOW_MS);
        }
    }
    return 0;
}

/* -------------------------------------------------------------------- rpc --- */

static void bridge_post(CaptureBridgeApp* app, const char* cmd) {
    furi_mutex_acquire(app->state_mutex, FURI_TIMEOUT_RELAXED);
    snprintf(app->pending_cmd, sizeof(app->pending_cmd), "%s", cmd);
    furi_mutex_release(app->state_mutex);
    furi_semaphore_release(app->cmd_sem);
}

static void bridge_reply(CaptureBridgeApp* app, const char* text) {
    if(!app->rpc) return;
    FuriString* out = furi_string_alloc_printf("%s\n", text);
    rpc_system_app_exchange_data(app->rpc, (const uint8_t*)furi_string_get_cstr(out), furi_string_size(out));
    furi_string_free(out);
}

static bool bridge_handle_command(CaptureBridgeApp* app, const char* cmd) {
    if(!strcmp(cmd, "ping")) {
        bridge_reply(app, "pong");
        return true;
    }
    if(!strcmp(cmd, "quit")) {
        bridge_reply(app, "bye");
        app->exit_requested = true;
        return true;
    }
    if(!strcmp(cmd, "result")) {
        char result[RESULT_LEN];
        furi_mutex_acquire(app->state_mutex, FURI_TIMEOUT_RELAXED);
        snprintf(result, sizeof(result), "%s", app->result);
        furi_mutex_release(app->state_mutex);
        bridge_reply(app, result);
        return true;
    }
    if(!strcmp(cmd, "status")) {
        if(app->capturing) {
            bridge_reply(app, "capturing");
        } else {
            char result[RESULT_LEN];
            furi_mutex_acquire(app->state_mutex, FURI_TIMEOUT_RELAXED);
            snprintf(result, sizeof(result), "%s", app->result);
            furi_mutex_release(app->state_mutex);
            bridge_reply(app, strcmp(result, "idle") ? result : "idle");
        }
        return true;
    }
    if(!strncmp(cmd, "rx", 2)) {
        if(app->capturing) {
            bridge_reply(app, "busy");
        } else {
            bridge_post(app, cmd);
            bridge_reply(app, "started");
        }
        return true;
    }
    bridge_reply(app, "err unknown");
    return true;
}

static void bridge_rpc_callback(const RpcAppSystemEvent* event, void* context) {
    CaptureBridgeApp* app = context;
    RpcAppSystem* rpc = app->rpc;
    if(!rpc) return;

    switch(event->type) {
    case RpcAppEventTypeSessionClose:
        app->exit_requested = true;
        break;
    case RpcAppEventTypeAppExit:
        rpc_system_app_confirm(rpc, true);
        app->exit_requested = true;
        break;
    case RpcAppEventTypeDataExchange: {
        bool handled = false;
        if(event->data.type == RpcAppSystemEventDataTypeString) {
            handled = bridge_handle_command(app, event->data.string);
        }
        rpc_system_app_confirm(rpc, handled);
        break;
    }
    default:
        rpc_system_app_confirm(rpc, true);
        break;
    }
}

/* -------------------------------------------------------------------- gui --- */

static void bridge_draw_callback(Canvas* canvas, void* context) {
    CaptureBridgeApp* app = context;
    char line[RESULT_LEN];
    furi_mutex_acquire(app->state_mutex, FURI_TIMEOUT_RELAXED);
    snprintf(line, sizeof(line), "%s", app->result);
    furi_mutex_release(app->state_mutex);

    canvas_set_font(canvas, FontPrimary);
    canvas_draw_str(canvas, 2, 12, "Capture Bridge");
    canvas_set_font(canvas, FontSecondary);
    canvas_draw_str(canvas, 2, 26, app->capturing ? "receiving..." : "OK: raw 433.92 MHz 3s");
    canvas_draw_str(canvas, 2, 38, line);
    canvas_draw_str(canvas, 2, 50, "USB/phone: rx <hz> <ms> | Back: exit");
}

static void bridge_input_callback(InputEvent* event, void* context) {
    CaptureBridgeApp* app = context;
    (void)furi_message_queue_put(app->input_queue, event, FURI_TIMEOUT_NO_WAIT);
}

/* ------------------------------------------------------------------- main --- */

static CaptureBridgeApp* bridge_alloc(void) {
    CaptureBridgeApp* app = malloc(sizeof(CaptureBridgeApp));
    furi_assert(app);
    memset(app, 0, sizeof(CaptureBridgeApp));
    app->state_mutex = furi_mutex_alloc(FuriMutexTypeNormal);
    app->cmd_sem = furi_semaphore_alloc(1, 0);
    app->rx_worker = subghz_worker_alloc();
    subghz_worker_set_pair_callback(app->rx_worker, bridge_pair_callback, app);
    subghz_worker_set_overrun_callback(app->rx_worker, bridge_overrun_callback);
    app->worker = furi_thread_alloc();
    furi_thread_set_name(app->worker, "CaptureBridge");
    furi_thread_set_stack_size(app->worker, WORKER_STACK);
    furi_thread_set_callback(app->worker, bridge_worker_thread);
    furi_thread_set_context(app->worker, app);
    snprintf(app->result, sizeof(app->result), "idle");
    return app;
}

static void bridge_teardown(CaptureBridgeApp* app) {
    furi_semaphore_release(app->cmd_sem);
    furi_thread_join(app->worker);
    furi_thread_free(app->worker);
    subghz_worker_free(app->rx_worker);
    furi_mutex_free(app->state_mutex);
    furi_semaphore_free(app->cmd_sem);
    free(app);
}

int32_t capture_bridge_app(void* p) {
    const char* args = p;
    bool rpc_mode = args && !strcmp(args, "RPC");

    CaptureBridgeApp* app = bridge_alloc();
    app->rpc_mode = rpc_mode;
    subghz_devices_init();

    if(rpc_mode) {
        app->rpc = furi_record_open(RECORD_RPC);
        rpc_system_app_set_callback(app->rpc, bridge_rpc_callback, app);
        rpc_system_app_send_started(app->rpc);
        FURI_LOG_I(TAG, "rpc mode up");
    } else {
        app->gui = furi_record_open(RECORD_GUI);
        app->input_queue = furi_message_queue_alloc(8, sizeof(InputEvent));
        app->view_port = view_port_alloc();
        view_port_draw_callback_set(app->view_port, bridge_draw_callback, app);
        view_port_input_callback_set(app->view_port, bridge_input_callback, app);
        gui_add_view_port(app->gui, app->view_port, GuiLayerFullscreen);
    }

    furi_thread_start(app->worker);

    if(rpc_mode) {
        while(!app->exit_requested) {
            furi_delay_ms(50);
        }
    } else {
        InputEvent event;
        while(!app->exit_requested) {
            if(furi_message_queue_get(app->input_queue, &event, 100) == FuriStatusOk) {
                if(event.type == InputTypeShort && event.key == InputKeyBack) {
                    app->exit_requested = true;
                } else if(event.type == InputTypeShort && event.key == InputKeyOk && !app->capturing) {
                    bridge_post(app, "rx 433920000 3000");
                }
            }
            view_port_update(app->view_port);
        }
    }

    if(app->rpc) {
        rpc_system_app_send_exited(app->rpc);
        rpc_system_app_set_callback(app->rpc, NULL, NULL);
        furi_record_close(RECORD_RPC);
        app->rpc = NULL;
    }
    if(!rpc_mode && app->gui) {
        gui_remove_view_port(app->gui, app->view_port);
        view_port_free(app->view_port);
        furi_message_queue_free(app->input_queue);
        furi_record_close(RECORD_GUI);
    }

    bridge_teardown(app);
    subghz_devices_deinit();
    return 0;
}
