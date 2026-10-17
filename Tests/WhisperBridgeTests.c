#include <assert.h>
#include <stdio.h>
#include <dlfcn.h>
#include <whisper.h>

static int library_token;
static int context_token;
static int backend_available;
static int backend_symbol_available = 1;
static int init_calls;
static int close_calls;
static int load_calls;
static int full_called;
static const char *runtime_version = "1.8.6";
static const char *mock_version(void) { return runtime_version; }

static void *mock_open(const char *path, int mode);
static void *mock_symbol(void *library, const char *name);
static int mock_close(void *library);
#define dlopen mock_open
#define dlsym mock_symbol
#define dlclose mock_close
#include "../Sources/WhisperBridge.c"
#undef dlopen
#undef dlsym
#undef dlclose

static void *mock_open(const char *path, int mode) {
    (void)path; (void)mode;
    return &library_token;
}
static int mock_close(void *library) {
    assert(library == &library_token);
    close_calls++;
    return 0;
}
static void *mock_backend_by_type(int type) {
    assert(type == 0); // GGML_BACKEND_DEVICE_TYPE_CPU
    return backend_available ? &library_token : NULL;
}
static struct whisper_context_params mock_params(void) {
    return (struct whisper_context_params){0};
}
static struct whisper_context *mock_init(const char *path, struct whisper_context_params params) {
    (void)path; (void)params;
    init_calls++;
    return (struct whisper_context *)&context_token;
}
static void mock_load(void) { load_calls++; backend_available = 1; }
static void mock_free(struct whisper_context *context) {
    assert(context == (struct whisper_context *)&context_token);
}
static struct whisper_full_params mock_full_params(enum whisper_sampling_strategy strategy) {
    (void)strategy;
    return (struct whisper_full_params){0};
}
static int mock_full(struct whisper_context *context, struct whisper_full_params params, const float *samples, int count) {
    (void)context; (void)samples; (void)count;
    // Automatic language must detect and TRANSCRIBE, not return detect-only.
    if (params.detect_language) return -1;
    assert(params.language == NULL || strcmp(params.language, "auto") == 0);
    full_called++;
    return 0;
}
static int mock_count(struct whisper_context *context) { (void)context; return 1; }
static const char *mock_text(struct whisper_context *context, int index) {
    (void)context; (void)index; return "synthetic transcript";
}
static void *mock_symbol(void *library, const char *name) {
    assert(library == &library_token);
    if (strcmp(name, "whisper_version") == 0) return mock_version;
    if (strcmp(name, "ggml_backend_dev_by_type") == 0)
        return backend_symbol_available ? mock_backend_by_type : NULL;
    if (strcmp(name, "whisper_context_default_params") == 0) return mock_params;
    if (strcmp(name, "whisper_init_from_file_with_params") == 0) return mock_init;
    if (strcmp(name, "ggml_backend_load_all") == 0) return mock_load;
    if (strcmp(name, "whisper_full_default_params") == 0) return mock_full_params;
    if (strcmp(name, "whisper_full") == 0) return mock_full;
    if (strcmp(name, "whisper_full_n_segments") == 0) return mock_count;
    if (strcmp(name, "whisper_full_get_segment_text") == 0) return mock_text;
    if (strcmp(name, "whisper_free") == 0) return mock_free;
    return NULL;
}
int main(void) {
    // A dynamically loaded library without a CPU backend must use CLI fallback.
    void *session = ff_whisper_create("synthetic-model.bin", "en");
    if (session != NULL || init_calls != 0 || close_calls != 1) {
        fprintf(stderr, "FAIL: missing CPU backend reached unsafe model initialization\n");
        return 1;
    }
    backend_symbol_available = 0;
    assert(ff_whisper_create("synthetic-model.bin", NULL) == NULL);
    assert(init_calls == 0 && close_calls == 2);

    backend_symbol_available = 1;
    backend_available = 1;
    session = ff_whisper_create("synthetic-model.bin", "en");
    assert(session != NULL && init_calls == 1);
    ff_whisper_destroy(session);
    assert(close_calls == 3);
    assert(load_calls == 0);
    backend_available = 0;
    session = ff_whisper_create_worker("synthetic-model.bin", "en");
    assert(session != NULL && init_calls == 2 && load_calls == 1);
    ff_whisper_destroy(session);
    session = ff_whisper_create_worker("synthetic-model.bin", NULL);
    float samples[] = {0};
    char output[128];
    int result = ff_whisper_transcribe(session, samples, 1, output, sizeof(output));
    if (result <= 0 || full_called != 1) {
        fprintf(stderr, "FAIL: automatic language did not run transcription\n");
        return 1;
    }
    assert(strcmp(output, "synthetic transcript") == 0);
    ff_whisper_destroy(session);
    int previous_init_calls = init_calls;
    runtime_version = "1.9.0";
    assert(ff_whisper_create_worker("synthetic-model.bin", NULL) == NULL);
    assert(init_calls == previous_init_calls);
    puts("Whisper bridge backend regression tests passed");
    return 0;
}
