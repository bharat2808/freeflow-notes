// Minimal compile-time API fixture. No model, audio, or installed Whisper is used.
#pragma once
#include <stdbool.h>
struct whisper_context { int unused; };
struct whisper_context_params { bool use_gpu; };
enum whisper_sampling_strategy { WHISPER_SAMPLING_GREEDY };
struct whisper_full_params {
    int n_threads;
    bool no_context, no_timestamps, single_segment;
    bool print_special, print_progress, print_realtime, print_timestamps;
    const char *language;
    bool detect_language;
};
