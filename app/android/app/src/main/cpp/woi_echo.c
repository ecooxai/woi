#include "woi_echo.h"
#include <stdlib.h>
#include <string.h>
#include "speex/speex_echo.h"
#include "speex/speex_preprocess.h"

typedef struct {
    SpeexEchoState *echo;
    SpeexPreprocessState *preprocess;
    int frame_size;
    int sample_rate;
    int quiet_frames;
    int tail_frames;
    int16_t *delayed_mic;
} WoiEcho;

static SpeexPreprocessState *new_preprocessor(WoiEcho *s) {
    SpeexPreprocessState *pre = speex_preprocess_state_init(s->frame_size, s->sample_rate);
    if (!pre) return NULL;
    speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_ECHO_STATE, s->echo);
    int enabled = 1, disabled = 0, noise_db = 0, echo_db = -45, double_talk_db = -6;
    speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_DENOISE, &enabled);
    speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &noise_db);
    speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_AGC, &disabled);
    speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, &echo_db);
    speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, &double_talk_db);
    return pre;
}

void *woi_echo_create(int sample_rate, int frame_size, int tail_samples) {
    if (sample_rate <= 0 || frame_size <= 0 || tail_samples < frame_size) return NULL;
    WoiEcho *s = (WoiEcho *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->frame_size = frame_size;
    s->sample_rate = sample_rate;
    s->tail_frames = (tail_samples + frame_size - 1) / frame_size;
    s->quiet_frames = s->tail_frames + 2;
    s->delayed_mic = (int16_t *)calloc((size_t)frame_size, sizeof(int16_t));
    s->echo = speex_echo_state_init(frame_size, tail_samples);
    s->preprocess = new_preprocessor(s);
    if (!s->echo || !s->preprocess || !s->delayed_mic) { woi_echo_destroy(s); return NULL; }
    speex_echo_ctl(s->echo, SPEEX_ECHO_SET_SAMPLING_RATE, &sample_rate);
    return s;
}

void woi_echo_destroy(void *state) {
    WoiEcho *s = (WoiEcho *)state;
    if (!s) return;
    if (s->preprocess) speex_preprocess_state_destroy(s->preprocess);
    if (s->echo) speex_echo_state_destroy(s->echo);
    free(s->delayed_mic);
    free(s);
}

int woi_echo_reset(void *state) {
    WoiEcho *s = (WoiEcho *)state;
    if (!s) return 0;
    // Reset all signal history, including the preprocess overlap/add buffer
    // and noise/SNR estimates. Resetting only the adaptive filter can replay
    // a pre-reset frame as soon as the next nonzero reference arrives.
    SpeexPreprocessState *replacement = new_preprocessor(s);
    if (!replacement) return 0;
    speex_echo_state_reset(s->echo);
    speex_preprocess_state_destroy(s->preprocess);
    s->preprocess = replacement;
    memset(s->delayed_mic, 0, (size_t)s->frame_size * sizeof(int16_t));
    s->quiet_frames = s->tail_frames + 2;
    return 1;
}

int woi_echo_process(void *state, const int16_t *mic, const int16_t *reference, int16_t *out, int count) {
    WoiEcho *s = (WoiEcho *)state;
    // The caller must submit whole frames. Reject invalid input before any
    // state/output mutation; never return an undelayed raw trailing fragment.
    if (!s || count < 0 || count % s->frame_size != 0) return -1;
    if (count == 0) return 0;
    if (!mic || !reference || !out) return -1;
    int off = 0;
    for (; off + s->frame_size <= count; off += s->frame_size) {
        int has_reference = 0;
        for (int i = 0; i < s->frame_size; ++i) has_reference |= reference[off + i] != 0;
        if (has_reference) s->quiet_frames = 0;
        else if (s->quiet_frames < s->tail_frames + 2) ++s->quiet_frames;
        speex_echo_cancellation(s->echo, mic + off, reference + off, out + off);
        speex_preprocess_run(s->preprocess, out + off);
        // With no render reference for an entire echo tail, suppressing speech
        // serves no purpose. Preserve it exactly, using the same one-frame
        // latency as Speex's overlap/add output so turn boundaries never skip
        // or repeat samples. Keep clocking the filter for the next reply.
        if (s->quiet_frames >= s->tail_frames + 2)
            memcpy(out + off, s->delayed_mic, (size_t)s->frame_size * sizeof(int16_t));
        memcpy(s->delayed_mic, mic + off, (size_t)s->frame_size * sizeof(int16_t));
    }
    return count;
}
