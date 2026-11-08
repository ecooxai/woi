#ifndef WOI_ECHO_H
#define WOI_ECHO_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void *woi_echo_create(int sample_rate, int frame_size, int tail_samples);
void woi_echo_destroy(void *state);
int woi_echo_reset(void *state);
// Returns processed samples, or -1 for a partial/invalid frame (state unchanged).
int woi_echo_process(void *state, const int16_t *mic, const int16_t *reference, int16_t *out, int count);
#ifdef __cplusplus
}
#endif
#endif
