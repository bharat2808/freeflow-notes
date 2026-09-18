#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <signal.h>

void *ff_whisper_create_worker(const char *, const char *);
int ff_whisper_transcribe(void *, const float *, int, char *, size_t);
void ff_whisper_destroy(void *);

// Private little-endian protocol (both supported macOS architectures are LE).
// Startup: magic. Request: uint32 sample count + float32 mono 16 kHz samples.
// Response: uint32 UTF-8 byte length + bytes; UINT32_MAX denotes failure.
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    signal(SIGPIPE, SIG_IGN);
    void *session = ff_whisper_create_worker(argv[1], argv[2][0] ? argv[2] : NULL);
    uint32_t ready = session ? 0x46574631 : 0x46574630;
    if (fwrite(&ready, sizeof(ready), 1, stdout) != 1 || fflush(stdout)) return 4;
    if (!session) return 3;
    char *text = malloc(1024 * 1024);
    if (!text) return 5;
    uint32_t count;
    while (fread(&count, sizeof(count), 1, stdin) == 1) {
        if (!count || count > 16000 * 300) break;
        float *samples = malloc((size_t)count * sizeof(float));
        if (!samples) break;
        if (fread(samples, sizeof(float), count, stdin) != count) { free(samples); break; }
        int valid = 1;
        for (uint32_t i = 0; i < count; i++) {
            if (!isfinite(samples[i])) { valid = 0; break; }
        }
        int length = valid ? ff_whisper_transcribe(session, samples, (int)count, text, 1024 * 1024) : -1;
        free(samples);
        uint32_t result = length < 0 ? UINT32_MAX : (uint32_t)length;
        if (fwrite(&result, sizeof(result), 1, stdout) != 1) break;
        if (length > 0 && fwrite(text, 1, (size_t)length, stdout) != (size_t)length) break;
        if (fflush(stdout)) break;
    }
    free(text);
    ff_whisper_destroy(session);
    return 0;
}
