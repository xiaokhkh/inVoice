#include "jam_ui.h"

#include <stdatomic.h>
#include <string.h>
#include "asset_store.h"
#include "bsp/esp-bsp.h"
#include "esp_check.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "gifdec.h"

#define GIF_TIMER_PERIOD_MS 10
#define UI_TIMER_PERIOD_MS 50
#define CONNECT_CELEBRATION_US 1200000

static const char *TAG = "jam_ui";

typedef enum {
    JAM_STATE_DISCONNECTED,
    JAM_STATE_READY,
    JAM_STATE_LISTENING,
    JAM_STATE_MUTED,
    JAM_STATE_ERROR,
    JAM_STATE_CONNECTED,
} jam_state_t;

static lv_obj_t *s_image;
static lv_obj_t *s_level_ring;
static lv_image_dsc_t s_image_descriptor;
static gd_GIF *s_gif;
static uint32_t s_last_frame_tick;
static jam_state_t s_rendered_state = (jam_state_t)-1;
static jam_ui_trigger_cb_t s_trigger_cb;
static uint8_t s_displayed_level;

static atomic_bool s_usb_connected;
static atomic_bool s_muted;
static atomic_bool s_trigger_active;
static atomic_bool s_error;
static atomic_int_fast64_t s_last_audio_us;
static atomic_int_fast64_t s_connected_at_us;
static atomic_uchar s_level_percent;
static char s_error_message[48];

static const char *state_asset(jam_state_t state)
{
    switch (state) {
    case JAM_STATE_CONNECTED:
        return "happy.gif";
    case JAM_STATE_LISTENING:
        return "thinking.gif";
    case JAM_STATE_MUTED:
    case JAM_STATE_DISCONNECTED:
        return "sleepy.gif";
    case JAM_STATE_ERROR:
        return "sad.gif";
    case JAM_STATE_READY:
    default:
        return "neutral.gif";
    }
}

static jam_state_t desired_state(void)
{
    const int64_t now = esp_timer_get_time();
    if (atomic_load(&s_error)) {
        return JAM_STATE_ERROR;
    }
    if (!atomic_load(&s_usb_connected)) {
        return JAM_STATE_DISCONNECTED;
    }
    if (atomic_load(&s_muted)) {
        return JAM_STATE_MUTED;
    }
    if (atomic_load(&s_trigger_active)) {
        return JAM_STATE_LISTENING;
    }
    const int64_t connected_at = atomic_load(&s_connected_at_us);
    if (connected_at > 0 && now - connected_at < CONNECT_CELEBRATION_US) {
        return JAM_STATE_CONNECTED;
    }
    return JAM_STATE_READY;
}

static esp_err_t load_gif(const char *name)
{
    const uint8_t *data = NULL;
    size_t size = 0;
    esp_err_t ret = asset_store_get(name, &data, &size);
    if (ret != ESP_OK) {
        return ret;
    }
    if (size < 6 || memcmp(data, "GIF", 3) != 0) {
        return ESP_ERR_INVALID_RESPONSE;
    }

    if (s_gif != NULL) {
        gd_close_gif(s_gif);
        s_gif = NULL;
    }
    s_gif = gd_open_gif_data(data);
    if (s_gif == NULL) {
        return ESP_FAIL;
    }
    s_gif->loop_count = 0;
    if (gd_get_frame(s_gif) <= 0) {
        gd_close_gif(s_gif);
        s_gif = NULL;
        return ESP_FAIL;
    }
    gd_render_frame(s_gif, s_gif->canvas);

    memset(&s_image_descriptor, 0, sizeof(s_image_descriptor));
    s_image_descriptor.header.magic = LV_IMAGE_HEADER_MAGIC;
    s_image_descriptor.header.flags = LV_IMAGE_FLAGS_MODIFIABLE;
    s_image_descriptor.header.cf = LV_COLOR_FORMAT_ARGB8888;
    s_image_descriptor.header.w = s_gif->width;
    s_image_descriptor.header.h = s_gif->height;
    s_image_descriptor.header.stride = s_gif->width * 4;
    s_image_descriptor.data = s_gif->canvas;
    s_image_descriptor.data_size = (uint32_t)s_gif->width * s_gif->height * 4;
    lv_image_set_src(s_image, &s_image_descriptor);
    lv_obj_center(s_image);
    lv_obj_set_y(s_image, -12);
    s_last_frame_tick = lv_tick_get();
    ESP_LOGI(TAG, "showing preserved Jam asset: %s", name);
    return ESP_OK;
}

static void gif_timer_cb(lv_timer_t *timer)
{
    (void)timer;
    if (s_gif == NULL) {
        return;
    }
    const uint32_t delay_ms = s_gif->gce.delay > 0 ? s_gif->gce.delay * 10U : 30U;
    if (lv_tick_elaps(s_last_frame_tick) < delay_ms) {
        return;
    }
    s_last_frame_tick = lv_tick_get();
    if (gd_get_frame(s_gif) > 0) {
        gd_render_frame(s_gif, s_gif->canvas);
        lv_obj_invalidate(s_image);
    }
}

static void ui_timer_cb(lv_timer_t *timer)
{
    (void)timer;
    const jam_state_t state = desired_state();
    if (state != s_rendered_state) {
        if (load_gif(state_asset(state)) != ESP_OK) {
            atomic_store(&s_error, true);
            strlcpy(s_error_message, "JAM ASSET ERROR", sizeof(s_error_message));
        } else {
            s_rendered_state = state;
        }
    }

    const uint8_t level = atomic_exchange(&s_level_percent, 0);
    if (level >= s_displayed_level) {
        s_displayed_level = level;
    } else {
        s_displayed_level = (uint8_t)((s_displayed_level * 3U) / 4U);
    }
    lv_arc_set_value(s_level_ring, s_displayed_level);
    if (state == JAM_STATE_LISTENING) {
        lv_obj_remove_flag(s_level_ring, LV_OBJ_FLAG_HIDDEN);
    } else {
        s_displayed_level = 0;
        lv_arc_set_value(s_level_ring, 0);
        lv_obj_add_flag(s_level_ring, LV_OBJ_FLAG_HIDDEN);
    }
}

static void trigger_event_cb(lv_event_t *event)
{
    if (s_trigger_cb == NULL) {
        return;
    }
    const lv_event_code_t code = lv_event_get_code(event);
    if (code == LV_EVENT_PRESSED) {
        s_trigger_cb(true);
    } else if (code == LV_EVENT_RELEASED || code == LV_EVENT_PRESS_LOST) {
        s_trigger_cb(false);
    }
}

static void add_hold_events(lv_obj_t *object)
{
    lv_obj_add_event_cb(object, trigger_event_cb, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(object, trigger_event_cb, LV_EVENT_RELEASED, NULL);
    lv_obj_add_event_cb(object, trigger_event_cb, LV_EVENT_PRESS_LOST, NULL);
}

esp_err_t jam_ui_init(lv_display_t *display, jam_ui_trigger_cb_t trigger_cb)
{
    if (display == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    ESP_RETURN_ON_ERROR(asset_store_init(), TAG, "preserved Jam assets unavailable");
    s_trigger_cb = trigger_cb;

    ESP_RETURN_ON_ERROR(bsp_display_lock(2000), TAG, "display lock failed");
    lv_obj_t *screen = lv_display_get_screen_active(display);
    lv_obj_set_style_bg_color(screen, lv_color_hex(0xf7f3e9), 0);
    lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);
    lv_obj_add_flag(screen, LV_OBJ_FLAG_CLICKABLE);
    add_hold_events(screen);

    s_image = lv_image_create(screen);
    lv_obj_add_flag(s_image, LV_OBJ_FLAG_CLICKABLE);
    add_hold_events(s_image);

    s_level_ring = lv_arc_create(screen);
    lv_obj_set_size(s_level_ring, 452, 452);
    lv_obj_center(s_level_ring);
    lv_arc_set_range(s_level_ring, 0, 100);
    lv_arc_set_bg_angles(s_level_ring, 0, 360);
    lv_arc_set_rotation(s_level_ring, 270);
    lv_arc_set_value(s_level_ring, 0);
    lv_obj_set_style_arc_width(s_level_ring, 12, LV_PART_MAIN);
    lv_obj_set_style_arc_color(s_level_ring, lv_color_hex(0xc9d9ce), LV_PART_MAIN);
    lv_obj_set_style_arc_opa(s_level_ring, LV_OPA_50, LV_PART_MAIN);
    lv_obj_set_style_arc_width(s_level_ring, 12, LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(s_level_ring, lv_color_hex(0x20d86b), LV_PART_INDICATOR);
    lv_obj_set_style_arc_rounded(s_level_ring, true, LV_PART_INDICATOR);
    lv_obj_set_style_bg_opa(s_level_ring, LV_OPA_TRANSP, LV_PART_KNOB);
    lv_obj_remove_flag(s_level_ring, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_flag(s_level_ring, LV_OBJ_FLAG_HIDDEN);

    atomic_store(&s_usb_connected, false);
    atomic_store(&s_muted, false);
    atomic_store(&s_trigger_active, false);
    atomic_store(&s_error, false);
    atomic_store(&s_last_audio_us, 0);
    atomic_store(&s_connected_at_us, 0);
    atomic_store(&s_level_percent, 0);
    s_displayed_level = 0;
    s_error_message[0] = '\0';

    lv_timer_create(gif_timer_cb, GIF_TIMER_PERIOD_MS, NULL);
    lv_timer_create(ui_timer_cb, UI_TIMER_PERIOD_MS, NULL);
    ui_timer_cb(NULL);
    bsp_display_unlock();
    return ESP_OK;
}

void jam_ui_set_usb_connected(bool connected)
{
    atomic_store(&s_usb_connected, connected);
    if (connected) {
        atomic_store(&s_connected_at_us, esp_timer_get_time());
    } else {
        atomic_store(&s_connected_at_us, 0);
        atomic_store(&s_last_audio_us, 0);
    }
}

void jam_ui_set_muted(bool muted)
{
    atomic_store(&s_muted, muted);
}

void jam_ui_set_trigger_active(bool active)
{
    atomic_store(&s_trigger_active, active);
    if (!active) {
        atomic_store(&s_last_audio_us, 0);
        atomic_store(&s_level_percent, 0);
    }
}

void jam_ui_note_audio(uint8_t level_percent)
{
    atomic_store(&s_last_audio_us, esp_timer_get_time());
    atomic_store(&s_level_percent, level_percent);
}

void jam_ui_set_error(const char *message)
{
    if (message != NULL) {
        strlcpy(s_error_message, message, sizeof(s_error_message));
    }
    atomic_store(&s_error, true);
}
