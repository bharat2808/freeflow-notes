#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Protocol fixture: no Whisper model, microphone or private data.
int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "";
    if (strstr(mode, "startup-hang")) { sleep(30); return 0; }
    uint32_t ready = strstr(mode, "unsupported") ? 0x46574630 : 0x46574631;
    fwrite(&ready, 4, 1, stdout); fflush(stdout);
    unsigned count = 0;
    uint32_t frames;
    while (fread(&frames, 4, 1, stdin) == 1) {
        float first = 0, value;
        for (uint32_t i = 0; i < frames; ++i) {
            if (fread(&value, 4, 1, stdin) != 1) return 2;
            if (i == 0) first = value;
        }
        if (first == 9) return 3;
        if (first == 8) { sleep(30); return 4; }
        if (first == 7) {
            uint32_t invalid = 0x7fffffff;
            fwrite(&invalid, 4, 1, stdout); fflush(stdout); continue;
        }
        if (first == 6) {
            char path[4096];
            snprintf(path, sizeof(path), "%s.busy", mode);
            FILE *marker = fopen(path, "w");
            if (marker) fclose(marker);
            usleep(500000);
        }
        char text[80];
        int32_t length = snprintf(text, sizeof(text), "synthetic-%u", ++count);
        fwrite(&length, 4, 1, stdout);
        fwrite(text, 1, (size_t)length, stdout); fflush(stdout);
    }
    return 0;
}
