// Ultra-lightweight (<2ms) quota statusLine for agy CLI.
// Parses agy's native stdin.quota ("gemini-5h" & "gemini-weekly"), merges with
// /tmp/agy-quota-state.json, and alternates every 11s (weekly in "Xd Yh").
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define ROTATE_SEC 11
#define CELLS 10

static void state_path(char *buf, size_t n) {
    const char *home = getenv("HOME");
    if (home && home[0]) {
        char dir[256];
        snprintf(dir, sizeof(dir), "%s/.cache", home);
        mkdir(dir, 0700);
        snprintf(dir, sizeof(dir), "%s/.cache/agy-hud", home);
        mkdir(dir, 0700);
        snprintf(buf, n, "%s/quota.json", dir);
    } else {
        snprintf(buf, n, "/tmp/agy-quota-state-%u.json", (unsigned)getuid());
    }
}

typedef struct {
    int valid;
    double rem;       // 0.0 .. 1.0
    long reset_epoch; // unix epoch
} Window;

static const char *color_for(int pct) {
    if (pct >= 90) return "\x1b[31m";
    if (pct >= 75) return "\x1b[33m";
    return "\x1b[36m";
}

static void fmt_until(long secs, int is_week, char *buf, size_t n) {
    if (secs <= 0) { buf[0] = '\0'; return; }
    long mins = (secs + 30) / 60;
    if (mins < 1) mins = 1;
    long hours = mins / 60;
    if (is_week || hours >= 24) {
        snprintf(buf, n, "%ldd %ldh", hours / 24, hours % 24);
    } else if (hours > 0) {
        snprintf(buf, n, "%ldh %ldm", hours, mins % 60);
    } else {
        snprintf(buf, n, "%ldm", mins);
    }
}

static int parse_obj_key(const char *src, const char *key, long now, Window *out) {
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = strstr(src, pat);
    if (!p) return 0;
    const char *brace = strchr(p, '{');
    if (!brace) return 0;
    const char *end = strchr(brace, '}');
    if (!end) return 0;

    // Skip disabled buckets
    const char *dis = strstr(brace, "\"disabled\"");
    if (dis && dis < end) {
        const char *t = strstr(dis, "true");
        if (t && t < end) return 0;
    }

    double rem = 0.0;
    int has_rem = 0;
    const char *rf = strstr(brace, "\"remaining_fraction\"");
    if (!rf || rf > end) rf = strstr(brace, "\"remaining\"");
    if (rf && rf < end) {
        const char *col = strchr(rf, ':');
        if (col && col < end) { rem = strtod(col + 1, NULL); has_rem = 1; }
    }

    long reset_epoch = 0;
    const char *re = strstr(brace, "\"reset_epoch\"");
    if (re && re < end) {
        const char *c2 = strchr(re, ':');
        if (c2 && c2 < end) reset_epoch = strtol(c2 + 1, NULL, 10);
    } else {
        const char *rs = strstr(brace, "\"reset_in_seconds\"");
        if (rs && rs < end) {
            const char *c2 = strchr(rs, ':');
            if (c2 && c2 < end) {
                long secs = strtol(c2 + 1, NULL, 10);
                if (secs > 0) reset_epoch = now + secs;
            }
        }
    }

    if (!has_rem && reset_epoch <= 0) return 0;
    out->valid = 1;
    out->rem = rem;
    out->reset_epoch = reset_epoch;
    return 1;
}

static void save_state(const char *path, const Window *w5, const Window *ww) {
    char tmp[320];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    FILE *f = fdopen(fd, "wb");
    if (!f) { close(fd); return; }
    fputc('{', f);
    int first = 1;
    if (w5->valid) {
        fprintf(f, "\"five_hour\":{\"remaining\":%.6f,\"reset_epoch\":%ld}", w5->rem, w5->reset_epoch);
        first = 0;
    }
    if (ww->valid) {
        if (!first) fputc(',', f);
        fprintf(f, "\"weekly\":{\"remaining\":%.6f,\"reset_epoch\":%ld}", ww->rem, ww->reset_epoch);
    }
    fputs("}\n", f);
    fclose(f);
    rename(tmp, path);
}

static void render_window(const char *label, const Window *w, int is_week, long now) {
    double r = w->rem < 0.0 ? 0.0 : (w->rem > 1.0 ? 1.0 : w->rem);
    int pct = (int)llround((1.0 - r) * 100.0);
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;

    int filled = (int)llround(((double)pct / 100.0) * CELLS);
    if (pct < 100 && filled >= CELLS) filled = CELLS - 1;
    if (filled < 0) filled = 0;
    if (filled > CELLS) filled = CELLS;

    const char *col = color_for(pct);
    char cd[32] = "";
    if (w->reset_epoch > now) fmt_until(w->reset_epoch - now, is_week, cd, sizeof(cd));

    printf("\x1b[2m%s\x1b[0m %s", label, col);
    for (int i = 0; i < filled; i++) fputs("━", stdout);
    fputs("\x1b[0m\x1b[2m", stdout);
    for (int i = filled; i < CELLS; i++) fputs("─", stdout);
    printf("\x1b[0m %s%d%%\x1b[0m", col, pct);
    if (cd[0]) printf(" \x1b[2m↻ %s\x1b[0m", cd);
    putchar('\n');
}

int main(void) {
    long now = (long)time(NULL);
    Window w5 = {0}, ww = {0};
    char spath[300];
    state_path(spath, sizeof(spath));

    // 1. Load cached state as baseline
    FILE *f = fopen(spath, "rb");
    if (f) {
        char buf[2048];
        size_t n = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
        buf[n] = '\0';
        parse_obj_key(buf, "five_hour", now, &w5);
        parse_obj_key(buf, "weekly", now, &ww);
    }

    // 2. Parse fresh stdin.quota from agy ("gemini-5h" & "gemini-weekly")
    char inbuf[16384];
    size_t in_n = fread(inbuf, 1, sizeof(inbuf) - 1, stdin);
    inbuf[in_n] = '\0';
    int updated = 0;
    if (in_n > 0) {
        const char *q = strstr(inbuf, "\"quota\"");
        if (q) {
            if (parse_obj_key(q, "gemini-5h", now, &w5)) updated = 1;
            if (parse_obj_key(q, "gemini-weekly", now, &ww)) updated = 1;
        }
    }

    // Expire past reset times
    if (w5.valid && w5.reset_epoch > 0 && w5.reset_epoch <= now) w5.valid = 0;
    if (ww.valid && ww.reset_epoch > 0 && ww.reset_epoch <= now) ww.valid = 0;

    if (updated) save_state(spath, &w5, &ww);
    if (!w5.valid && !ww.valid) return 0;

    int show_week = (w5.valid && ww.valid) ? (((now / ROTATE_SEC) % 2) == 1) : ww.valid;
    if (show_week) render_window("week", &ww, 1, now);
    else           render_window("5h", &w5, 0, now);
    return 0;
}
