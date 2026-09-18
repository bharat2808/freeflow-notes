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
static void mock_free(struct whisper_context *context) {
    assert(context == (struct whisper_context *)&context_token);
}
static void *mock_symbol(void *library, const char *name) {
    assert(library == &library_token);
    if (strcmp(name, "ggml_backend_dev_by_type") == 0)
        return backend_symbol_available ? mock_backend_by_type : NULL;
    if (strcmp(name, "whisper_context_default_params") == 0) return mock_params;
    if (strcmp(name, "whisper_init_from_file_with_params") == 0) return mock_init;
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
    puts("Whisper bridge backend regression tests passed");
    return 0;
}
