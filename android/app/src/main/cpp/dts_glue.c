/*
 * dts_glue.c — baiji-music QQ 音乐臻品 DTS:X（DT03）解码原生模块
 *
 * 链路：dlopen 官方 DTSPlaybackSDK.so → InitialiseDTS(自备 instance 槽)
 *       → InstallLicense(dts_hpx.lic) → LoadConfiguration(dts_config.yaml)
 *       → 自实现 MP4 demux 提取 dtsx ES → DTSPlayback_DecodeDTS 循环 → WAV
 *
 * C API 签名经 arm64/v7a 双 ABI QEMU 逆向验证（2026-10）：
 *   int DTSPlayback_InitialiseDTS(void *ctx_slot);          // *ctx_slot = instance, 返回 0 成功
 *   int DTSPlayback_InstallLicense(void *inst, const uint8_t *lic, int len);
 *   int DTSPlayback_LoadConfiguration(void *inst, const uint8_t *cfg, int len, const char **err);
 *   int DTSPlayback_DecodeDTS(void *inst, const uint8_t *es, unsigned size,
 *                             int *consumed, int *och, int *ofr, float ***planar);
 *   int DTSPlayback_SetOutputChannelLayout(void *inst, int layout);
 * planar 为输出参数：SDK 写入内部 planar float 缓冲（planar[ch][frame]）。
 *
 * Dart FFI 调用，见 lib/dts/dts_decoder.dart。
 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <android/log.h>

#define TAG "dts_glue"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

typedef int (*FnInitialise)(void *);
typedef int (*FnInstallLicense)(void *, const unsigned char *, int);
typedef int (*FnLoadConfig)(void *, const unsigned char *, int, const char **);
typedef int (*FnDecodeDTS)(void *, const unsigned char *, unsigned int,
                           int *, int *, int *, float ***);
typedef int (*FnSetLayout)(void *, int);
typedef int (*FnFlush)(void *);

static void *g_sdk = NULL;          /* dlopen handle */
static void *g_instance = NULL;     /* DTSPlayback instance */
static FnDecodeDTS g_decode = NULL;

/* ===================== MP4 demux（dtsx 轨） ===================== */

typedef struct {
    unsigned int count;        /* sample (ES frame) count */
    unsigned int *sizes;
    unsigned int nchunks;
    unsigned int *chunk_off;   /* 0-based chunk -> file offset */
    unsigned int *chunk_first; /* stsc first_chunk (1-based) */
    unsigned int *chunk_spc;
    unsigned int nsc;
    unsigned int *offsets;     /* sample idx -> absolute file offset */
    long msize;
    unsigned char *data;       /* whole mp4 mmap-like buffer */
    unsigned int timescale;    /* mdia/mdhd timescale (fallback 48000) */
} Mp4Dtsx;

static unsigned int rd32(const unsigned char *b)
{
    return ((unsigned int)b[0] << 24) | ((unsigned int)b[1] << 16) |
           ((unsigned int)b[2] << 8) | (unsigned int)b[3];
}

static unsigned long long rd64(const unsigned char *b)
{
    return ((unsigned long long)rd32(b) << 32) | rd32(b + 4);
}

/* ---- 解析单个 trak：fourcc 必须为 dtsx ---- */
static int parse_trak_dtsx(Mp4Dtsx *m, long trak_off, long trak_size)
{
    /* find stbl inside this trak */
    long o = trak_off, end = trak_off + trak_size;
    long stbl_off = -1, stbl_size = 0;
    while (o + 8 <= end) {
        unsigned long long sz = rd32(m->data + o);
        long body = o + 8;
        if (sz == 1) { sz = rd64(m->data + o + 8); body = o + 16; }
        if (sz < 8 || o + (long)sz > end) break;
        if (!memcmp(m->data + o + 4, "mdia", 4)) {
            long o2 = body, end2 = body + (long)sz - 8;
            while (o2 + 8 <= end2) {
                unsigned long long sz2 = rd32(m->data + o2);
                long body2 = o2 + 8;
                if (sz2 == 1) { sz2 = rd64(m->data + o2 + 8); body2 = o2 + 16; }
                if (sz2 < 8 || o2 + (long)sz2 > end2) break;
                if (!memcmp(m->data + o2 + 4, "minf", 4)) {
                    long o3 = body2, end3 = body2 + (long)sz2 - 8;
                    while (o3 + 8 <= end3) {
                        unsigned long long sz3 = rd32(m->data + o3);
                        long body3 = o3 + 8;
                        if (sz3 == 1) { sz3 = rd64(m->data + o3 + 8); body3 = o3 + 16; }
                        if (sz3 < 8 || o3 + (long)sz3 > end3) break;
                        if (!memcmp(m->data + o3 + 4, "stbl", 4)) {
                            stbl_off = body3;
                            stbl_size = (long)sz3 - 8;
                            break;
                        }
                        o3 += (long)sz3;
                    }
                    break;
                }
                o2 += (long)sz2;
            }
            break;
        }
        o += (long)sz;
    }
    if (stbl_off < 0) return -1;

    /* stsd: check fourcc == dtsx */
    long o4 = stbl_off, stbl_end = stbl_off + stbl_size;
    long stsd_body = -1;
    while (o4 + 8 <= stbl_end) {
        unsigned long long sz = rd32(m->data + o4);
        if (sz == 1) sz = rd64(m->data + o4 + 8);
        if (sz < 8) break;
        if (!memcmp(m->data + o4 + 4, "stsd", 4)) {
            stsd_body = o4 + 8; /* ver/flags + entry_count (8 bytes) then sample entries */
            break;
        }
        o4 += (long)sz;
    }
    if (stsd_body < 0 || stsd_body + 12 > stbl_end) return -1;
    /* stsd body: ver/flags(4) + entry_count(4)，随后是 sample entry box：
     * [size(4)][fourcc(4)][...] —— fourcc 在 stsd_body + 12 */
    if (memcmp(m->data + stsd_body + 12, "dtsx", 4) != 0) return -1; /* not the DTS:X track */

    /* stsz */
    long off, size;
    o4 = stbl_off;
    off = size = -1;
    while (o4 + 8 <= stbl_end) {
        unsigned long long sz = rd32(m->data + o4);
        if (sz == 1) sz = rd64(m->data + o4 + 8);
        if (sz < 8) break;
        if (!memcmp(m->data + o4 + 4, "stsz", 4)) { off = o4 + 8; size = (long)sz - 8; break; }
        o4 += (long)sz;
    }
    if (off < 0 || size < 12) return -1;
    unsigned int ssz = rd32(m->data + off + 4);
    unsigned int cnt = rd32(m->data + off + 8);
    if (cnt == 0 || cnt > 2000000) return -1;
    m->count = cnt;
    m->sizes = (unsigned int *)malloc((size_t)cnt * 4);
    if (!m->sizes) return -1;
    if (ssz) {
        for (unsigned int i = 0; i < cnt; i++) m->sizes[i] = ssz;
    } else {
        for (unsigned int i = 0; i < cnt; i++) {
            if (off + 12 + (long)i * 4 + 4 > stbl_end) { free(m->sizes); m->sizes = NULL; return -1; }
            m->sizes[i] = rd32(m->data + off + 12 + (size_t)i * 4);
        }
    }

    /* stco (32-bit) or co64 (64-bit) */
    o4 = stbl_off;
    off = size = -1;
    int is_co64 = 0;
    while (o4 + 8 <= stbl_end) {
        unsigned long long sz = rd32(m->data + o4);
        if (sz == 1) sz = rd64(m->data + o4 + 8);
        if (sz < 8) break;
        if (!memcmp(m->data + o4 + 4, "stco", 4)) { off = o4 + 8; size = (long)sz - 8; break; }
        if (!memcmp(m->data + o4 + 4, "co64", 4)) { off = o4 + 8; size = (long)sz - 8; is_co64 = 1; break; }
        o4 += (long)sz;
    }
    if (off < 0 || size < 8) return -1;
    m->nchunks = rd32(m->data + off + 4);
    if (m->nchunks == 0 || m->nchunks > 2000000) return -1;
    m->chunk_off = (unsigned int *)malloc((size_t)m->nchunks * 4);
    if (!m->chunk_off) return -1;
    for (unsigned int i = 0; i < m->nchunks; i++) {
        if (is_co64) {
            unsigned long long v = rd64(m->data + off + 8 + (size_t)i * 8);
            m->chunk_off[i] = (unsigned int)(v & 0xFFFFFFFFu); /* QQ 音乐样本表 32 位足够 */
        } else {
            m->chunk_off[i] = rd32(m->data + off + 8 + (size_t)i * 4);
        }
    }

    /* stsc */
    o4 = stbl_off;
    off = size = -1;
    while (o4 + 8 <= stbl_end) {
        unsigned long long sz = rd32(m->data + o4);
        if (sz == 1) sz = rd64(m->data + o4 + 8);
        if (sz < 8) break;
        if (!memcmp(m->data + o4 + 4, "stsc", 4)) { off = o4 + 8; size = (long)sz - 8; break; }
        o4 += (long)sz;
    }
    if (off < 0 || size < 8) return -1;
    m->nsc = rd32(m->data + off + 4);
    if (m->nsc == 0 || m->nsc > 2000000) return -1;
    m->chunk_first = (unsigned int *)malloc((size_t)m->nsc * 4);
    m->chunk_spc = (unsigned int *)malloc((size_t)m->nsc * 4);
    if (!m->chunk_first || !m->chunk_spc) return -1;
    for (unsigned int i = 0; i < m->nsc; i++) {
        m->chunk_first[i] = rd32(m->data + off + 8 + (size_t)i * 12);
        m->chunk_spc[i] = rd32(m->data + off + 12 + (size_t)i * 12);
    }
    return 0;
}

static unsigned int spc_for_chunk(const Mp4Dtsx *m, unsigned int c)
{
    for (unsigned int i = 0; i < m->nsc; i++) {
        unsigned int first = m->chunk_first[i] - 1;
        unsigned int next = (i + 1 < m->nsc) ? m->chunk_first[i + 1] - 1 : m->nchunks;
        if (c >= first && c < next) return m->chunk_spc[i];
    }
    return m->chunk_spc[m->nsc - 1];
}

static int build_offsets(Mp4Dtsx *m)
{
    m->offsets = (unsigned int *)malloc((size_t)m->count * 4);
    if (!m->offsets) return -1;
    unsigned int sidx = 0;
    for (unsigned int c = 0; c < m->nchunks && sidx < m->count; c++) {
        unsigned int spc = spc_for_chunk(m, c);
        unsigned int n = (sidx + spc > m->count) ? m->count - sidx : spc;
        m->offsets[sidx] = m->chunk_off[c];
        for (unsigned int k = 1; k < n; k++)
            m->offsets[sidx + k] = m->offsets[sidx + k - 1] + m->sizes[sidx + k - 1];
        sidx += n;
    }
    return sidx == m->count ? 0 : -1;
}

static void mp4_free(Mp4Dtsx *m)
{
    free(m->sizes); free(m->chunk_off); free(m->chunk_first); free(m->chunk_spc); free(m->offsets);
    free(m->data);
    memset(m, 0, sizeof(*m));
}

/* ===================== WAV 写出 ===================== */

static void put32(FILE *f, unsigned int v) { fwrite(&v, 4, 1, f); }
static void put16(FILE *f, unsigned short v) { fwrite(&v, 2, 1, f); }

static void wav_write_header(FILE *f, unsigned int data_bytes, int ch, int rate)
{
    fseek(f, 0, SEEK_SET);
    fwrite("RIFF", 1, 4, f);
    put32(f, 36 + data_bytes);
    fwrite("WAVEfmt ", 1, 8, f);
    put32(f, 16);
    put16(f, 1);              /* PCM */
    put16(f, (unsigned short)ch);
    put32(f, (unsigned int)rate);
    put32(f, (unsigned int)(rate * ch * 2));
    put16(f, (unsigned short)(ch * 2));
    put16(f, 16);
    fwrite("data", 1, 4, f);
    put32(f, data_bytes);
}

/* ===================== 对外 API（Dart FFI） ===================== */

void dtsglue_close(void);


void dtsglue_log(const char *msg) { LOGI("%s", msg ? msg : ""); }

/* 探测本机是否可用（so 存在且能 dlopen + 符号齐全） */
int dtsglue_abi_available(void)
{
    if (g_sdk) return 1; /* already loaded */
    void *h = dlopen("libDTSPlaybackSDK.so", RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        LOGW("probe dlopen failed: %s", dlerror());
        return 0;
    }
    int ok = dlsym(h, "DTSPlayback_InitialiseDTS") != NULL &&
             dlsym(h, "DTSPlayback_InstallLicense") != NULL &&
             dlsym(h, "DTSPlayback_LoadConfiguration") != NULL &&
             dlsym(h, "DTSPlayback_DecodeDTS") != NULL;
    dlclose(h);
    return ok ? 1 : 0;
}

/*
 * 初始化 SDK 并注入许可/配置。
 * lic/cfg 路径通常为 App assets 解包后的私有目录文件。
 * 返回 0 成功；-1 dlopen/符号缺失；-2 Initialise 失败；-3 许可失败；-4 配置失败。
 */
int dtsglue_init(const char *lic_path, const char *cfg_path)
{
    if (g_instance) return 0; /* 已初始化（进程内复用单实例） */
    g_sdk = dlopen("libDTSPlaybackSDK.so", RTLD_NOW | RTLD_LOCAL);
    if (!g_sdk) {
        LOGE("dlopen DTSPlaybackSDK: %s", dlerror());
        return -1;
    }
    FnInitialise init = (FnInitialise)dlsym(g_sdk, "DTSPlayback_InitialiseDTS");
    FnInstallLicense lic = (FnInstallLicense)dlsym(g_sdk, "DTSPlayback_InstallLicense");
    FnLoadConfig cfg = (FnLoadConfig)dlsym(g_sdk, "DTSPlayback_LoadConfiguration");
    g_decode = (FnDecodeDTS)dlsym(g_sdk, "DTSPlayback_DecodeDTS");
    FnSetLayout layout = (FnSetLayout)dlsym(g_sdk, "DTSPlayback_SetOutputChannelLayout");
    if (!init || !lic || !cfg || !g_decode) {
        LOGE("missing SDK symbols");
        return -1;
    }
    /* ctx = 调用方 instance 槽（QM 层同款调用形态） */
    static void *slot;
    slot = NULL;
    int rc = init(&slot);
    if (rc != 0 || !slot) {
        LOGE("InitialiseDTS rc=%d slot=%p", rc, slot);
        return -2;
    }
    g_instance = slot;
    if (layout) layout(g_instance, 1); /* 官方 sample 的输出声道布局 */

    FILE *f = fopen(lic_path, "rb");
    if (!f) { LOGE("lic open %s", lic_path); return -3; }
    fseek(f, 0, SEEK_END); long ln = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *licbuf = (unsigned char *)malloc((size_t)ln + 1);
    if (fread(licbuf, 1, (size_t)ln, f) != (size_t)ln) ln = 0;
    fclose(f);
    rc = lic(g_instance, licbuf, (int)ln);
    free(licbuf);
    LOGI("InstallLicense(%ld bytes) = %d", ln, rc);
    if (rc != 0) return -3;

    f = fopen(cfg_path, "rb");
    if (!f) { LOGE("cfg open %s", cfg_path); return -4; }
    fseek(f, 0, SEEK_END); long cn = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *cfgbuf = (unsigned char *)malloc((size_t)cn + 1);
    cfgbuf[cn] = 0;
    if (fread(cfgbuf, 1, (size_t)cn, f) != (size_t)cn) cn = 0;
    fclose(f);
    const char *err = NULL;
    rc = cfg(g_instance, cfgbuf, (int)cn, &err);
    free(cfgbuf);
    LOGI("LoadConfiguration(%ld bytes) = %d err=%s", cn, rc, err ? err : "(none)");
    if (rc != 0) return -4;
    return 0;
}

/*
 * 打开 DT03 mp4 并解析 dtsx 轨。返回 0 成功；负数失败。
 */
static Mp4Dtsx g_mp4;

int dtsglue_open(const char *mp4_path)
{
    if (!g_instance) return -10;
    dtsglue_close();
    memset(&g_mp4, 0, sizeof(g_mp4));
    FILE *f = fopen(mp4_path, "rb");
    if (!f) { LOGE("open %s", mp4_path); return -11; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 1024 || n > 512L * 1024 * 1024) { fclose(f); return -12; }
    g_mp4.data = (unsigned char *)malloc((size_t)n);
    if (!g_mp4.data || fread(g_mp4.data, 1, (size_t)n, f) != (size_t)n) {
        fclose(f); mp4_free(&g_mp4); return -12;
    }
    fclose(f);
    g_mp4.msize = n;

    /* 遍历 moov/trak，找 fourcc=dtsx 的音轨 */
    long moov_body = -1, moov_size = 0;
    {
        long o = 0;
        while (o + 8 <= n) {
            unsigned long long sz = rd32(g_mp4.data + o);
            long body = o + 8;
            if (sz == 1) { sz = rd64(g_mp4.data + o + 8); body = o + 16; }
            if (sz < 8 || o + (long)sz > n) break;
            if (!memcmp(g_mp4.data + o + 4, "moov", 4)) { moov_body = body; moov_size = (long)sz - 8; break; }
            o += (long)sz;
        }
    }
    if (moov_body < 0) { mp4_free(&g_mp4); return -13; }
    int found = 0;
    long o = moov_body, end = moov_body + moov_size;
    while (o + 8 <= end) {
        unsigned long long sz = rd32(g_mp4.data + o);
        long body = o + 8;
        if (sz == 1) { sz = rd64(g_mp4.data + o + 8); body = o + 16; }
        if (sz < 8 || o + (long)sz > end) break;
        if (!memcmp(g_mp4.data + o + 4, "trak", 4)) {
            if (parse_trak_dtsx(&g_mp4, body, (long)sz - 8) == 0) { found = 1; break; }
        }
        o += (long)sz;
    }
    if (!found) { LOGE("no dtsx track"); mp4_free(&g_mp4); return -14; }
    if (build_offsets(&g_mp4) < 0) { mp4_free(&g_mp4); return -15; }
    LOGI("dtsx track: samples=%u chunks=%u runs=%u", g_mp4.count, g_mp4.nchunks, g_mp4.nsc);
    return 0;
}

unsigned int dtsglue_total_samples(void) { return g_mp4.count; }

/*
 * 全曲解码 → 16-bit 交错 PCM WAV。
 * progress(pct, user)：pct 0~100，可在任意线程回调；传 NULL 忽略。
 * 返回 0 成功；负数失败。
 */
int dtsglue_decode_to_wav(const char *wav_path,
                          void (*progress)(int, void *), void *user)
{
    if (!g_instance || !g_mp4.count || !g_decode) return -20;
    FILE *w = fopen(wav_path, "wb");
    if (!w) { LOGE("wav open %s", wav_path); return -21; }
    wav_write_header(w, 0, 2, 48000); /* 占位：声道数/时长解码后回填 */

    FILE *raw = tmpfile();
    if (!raw) { fclose(w); return -22; }
    int ch = 0, frames_total = 0, first_bad = -1;
    long long dropped = 0;
    float **planar = NULL;
    int last_pct = -1;
    for (unsigned int i = 0; i < g_mp4.count; i++) {
        int consumed = 0, och = 0, ofr = 0;
        int rc = g_decode(g_instance, g_mp4.data + g_mp4.offsets[i], g_mp4.sizes[i],
                          &consumed, &och, &ofr, &planar);
        if (rc == 0 && och > 0 && ofr > 0) {
            ch = och;
            frames_total += ofr;
            for (int fr = 0; fr < ofr; fr++)
                for (int c = 0; c < och; c++)
                    fwrite(&planar[c][fr], 4, 1, raw);
        } else {
            if (first_bad < 0) {
                LOGW("frame %u rc=%d consumed=%d och=%d ofr=%d", i, rc, consumed, och, ofr);
                first_bad = (int)i;
            }
            dropped++;
        }
        if (progress && (int)((i * 100) / g_mp4.count) != last_pct) {
            last_pct = (int)((i * 100) / g_mp4.count);
            progress(last_pct, user);
        }
    }
    LOGI("decoded frames=%d ch=%d dropped=%lld first_bad=%d", frames_total, ch, dropped, first_bad);

    /* float -> s16 交错 */
    if (ch <= 0 || frames_total <= 0) { fclose(raw); fclose(w); return -23; }
    fseek(raw, 0, SEEK_END);
    long fsz = ftell(raw);
    fseek(raw, 0, SEEK_SET);
    long nsamp = fsz / 4;
    float *buf = (float *)malloc((size_t)fsz);
    short *s16 = (short *)malloc((size_t)nsamp * 2);
    if (!buf || !s16 || fread(buf, 4, (size_t)nsamp, raw) != (size_t)nsamp) {
        free(buf); free(s16); fclose(raw); fclose(w); return -24;
    }
    fclose(raw);
    for (long i = 0; i < nsamp; i++) {
        float v = buf[i];
        if (v > 1.0f) v = 1.0f;
        if (v < -1.0f) v = -1.0f;
        s16[i] = (short)(v * 32767.0f);
    }
    free(buf);
    int rate = 48000;
    if (g_mp4.timescale > 0 && g_mp4.timescale != 1) rate = (int)g_mp4.timescale;
    unsigned int dsz = (unsigned int)(nsamp * 2);
    wav_write_header(w, dsz, ch, rate);
    fseek(w, 0, SEEK_END);
    fwrite(s16, 1, (size_t)dsz, w);
    free(s16);
    fclose(w);
    if (progress) progress(100, user);
    return dropped > 0 && frames_total == 0 ? -25 : 0;
}

void dtsglue_close(void)
{
    mp4_free(&g_mp4);
}

void dtsglue_release(void)
{
    dtsglue_close();
    if (g_sdk) {
        FnFlush flush = (FnFlush)dlsym(g_sdk, "DTSPlayback_Flush");
        typedef int (*FnRel)(void *);
        FnRel rel = (FnRel)dlsym(g_sdk, "DTSPlayback_Release");
        if (rel && g_instance) rel(g_instance);
        else if (flush && g_instance) flush(g_instance);
        (void)flush;
        dlclose(g_sdk);
        g_sdk = NULL;
        g_instance = NULL;
        g_decode = NULL;
    }
}

/* 供未来流式播放用的单帧解码（预留，当前版本用不到）
int dtsglue_read_pcm(short *out, int max_interleaved)
{
    if (!g_instance || !g_decode || !g_mp4.count) return 0;
    ...
}
*/
