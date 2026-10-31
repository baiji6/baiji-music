/*
 * ra360_glue.cpp — baiji-music QQ 音乐索尼 360RA（RA01-04）解码原生模块
 *
 * 链路：dlopen 官方 qm_native_decoder_360ra.so（QQ 音乐 CDN 下发，
 *       MD5 锚定 43a08ecaac99b81368934d150166421a；其 NEEDED 依赖
 *       libaudio_common.so / libextra_mp4_parser.so 由 jniLibs 一并打包，
 *       bionic dlopen 按 SONAME 自动加载，无需手动干预）
 *   → create_SonyIaNativeDecoder()
 *   → setCoefPath(appRoot, configRelPath, cpRelPath)
 *     * coefPath1 指向【config 文件】（非 hki 本体！），内容为 hki 的
 *       相对路径行（反汇编 sia_virtualizer_getHandle 验证：native 拼接
 *       appRoot + '/' + coefPath1 读 config，取首行再拼 appRoot 加载 hki）
 *   → setSpkFilePath(spkRelPath)（可选，扬声器 VBAP 参数）
 *   → init(自实现 IDataSource) → getMinBufferSize → decode 循环 → WAV
 *
 * 输出：48kHz / 32-bit int / 双声道交错 PCM（binaural 渲染结果），
 *       与官方播放内核输出一致（QEMU 全曲验证 2026-10-31）。
 *
 * C API（Dart FFI 见 lib/ra360/ra360_decoder.dart）：
 *   int  ra360glue_abi_available(void)                       探测三 so + 符号
 *   const char *ra360glue_probe_detail(void)                 探测失败详情
 *   int  ra360glue_init(appRoot, configRel, cpRel, spkRel)   创建 decoder + 系数
 *   int  ra360glue_open(const char *mp4_path)                打开 MHA1 mp4
 *   int  ra360glue_decode_to_wav(wav, progress, user)        全曲解码 → WAV
 *   void ra360glue_close(void)                               关闭当前曲目
 *   void ra360glue_release(void)                             销毁 decoder
 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __ANDROID__
#include <android/log.h>
#define TAG "ra360_glue"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
#else
/* 桌面/QEMU 验证构建：日志走 stderr */
#define LOGI(...) do { fprintf(stderr, "[ra360_glue] "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } while (0)
#define LOGW LOGI
#define LOGE LOGI
#endif

#include <string>

/* ===================== 官方 decoder 接口（QEMU 逆向验证） ===================== */

/* IDataSource 纯虚接口 —— 与 SonyIaNativeDecoder 的 ABI 完全一致（Itanium）。
 * read 的第 2 参数实测为请求长度、第 3 参数未知（头部读取时 0、后续为大值），
 * 官方实现不依赖它，忽略即可（QEMU 全曲验证通过）。 */
class IDataSource {
public:
    virtual int open() = 0;
    virtual int read(void *buf, int size, int flag) = 0;
    virtual int seek(long offset, int whence) = 0;
    virtual int close() = 0;
    virtual int getSize(unsigned long *size) = 0;
    virtual long getCurPosition() = 0;
    virtual ~IDataSource() {}
    virtual std::string getFilePath() = 0;
};

typedef void *(*FnCreate)();
typedef void (*FnDestroy)(void *);
typedef int (*FnInit)(void *, IDataSource *);
typedef int (*FnIntFn)(void *);
typedef long (*FnDecode)(void *, unsigned char *, unsigned long, unsigned long);
typedef void (*FnSetCoef)(void *, const char *, const char *, const char *);
typedef void (*FnSetSpk)(void *, const char *);

/* ===================== 文件数据源 ===================== */

class FileDS : public IDataSource {
public:
    FILE *fp = NULL;
    std::string path;

    int open() override { return fp ? 0 : -1; }
    int read(void *buf, int size, int /*flag*/) override {
        if (!fp || size <= 0) return 0;
        return (int)fread(buf, 1, (size_t)size, fp);
    }
    int seek(long offset, int whence) override {
        if (!fp) return -1;
        return fseek(fp, offset, whence == 0 ? SEEK_SET
                              : whence == 1 ? SEEK_CUR : SEEK_END);
    }
    int close() override { return 0; }
    int getSize(unsigned long *size) override {
        if (!fp || !size) return -1;
        long save = ftell(fp);
        fseek(fp, 0, SEEK_END);
        *size = (unsigned long)ftell(fp);
        fseek(fp, save, SEEK_SET);
        return 0;
    }
    long getCurPosition() override { return fp ? ftell(fp) : 0; }
    std::string getFilePath() override { return path; }
};

/* ===================== 全局状态 ===================== */

static void *g_dec = NULL;          /* SonyIaNativeDecoder 实例 */
static void *g_lib = NULL;          /* dlopen 句柄 */
static FileDS *g_ds = NULL;         /* 当前曲目数据源 */
static FnDecode g_decode = NULL;
static FnIntFn g_getMinBuf = NULL;
static int g_minbuf = 0;
static char g_probe_err[256];

/* ===================== WAV 写出 ===================== */

static void put32(FILE *f, unsigned int v) { fwrite(&v, 4, 1, f); }
static void put16(FILE *f, unsigned short v) { fwrite(&v, 2, 1, f); }

/* 32-bit int PCM WAV 头（48kHz/2ch；data_bytes 解码完回填） */
static void wav_write_header(FILE *f, unsigned int data_bytes)
{
    fseek(f, 0, SEEK_SET);
    fwrite("RIFF", 1, 4, f);
    put32(f, 36 + data_bytes);
    fwrite("WAVEfmt ", 1, 8, f);
    put32(f, 16);
    put16(f, 1);        /* PCM */
    put16(f, 2);        /* 双声道（binaural） */
    put32(f, 48000);
    put32(f, 48000 * 2 * 4);
    put16(f, 2 * 4);
    put16(f, 32);
    fwrite("data", 1, 4, f);
    put32(f, data_bytes);
}

/* ===================== 对外 API（Dart FFI，C 导出） ===================== */

extern "C" {

void ra360glue_close(void);

const char *ra360glue_probe_detail(void)
{
    return g_probe_err[0] ? g_probe_err : "ok";
}

/* 探测本机可用性：decoder so 能 dlopen（依赖自动满足）+ 符号齐全。
 * 官方只为 arm64-v8a 下发（QQ 音乐 so_info.json 仅此 ABI），v7a/x86 无库，
 * 探测失败后 Dart 层走音质降级链自动绕开。 */
int ra360glue_abi_available(void)
{
    if (g_lib) return 1;
    void *h = dlopen("qm_native_decoder_360ra.so", RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        const char *e = dlerror();
        LOGW("probe dlopen failed: %s", e ? e : "(no dlerror)");
        snprintf(g_probe_err, sizeof(g_probe_err), "dlopen: %s", e ? e : "unknown");
        return 0;
    }
    int ok = dlsym(h, "create_SonyIaNativeDecoder") != NULL &&
             dlsym(h, "destroy_SonyIaNativeDecoder") != NULL &&
             dlsym(h, "_ZN19SonyIaNativeDecoder4initEP11IDataSource") != NULL &&
             dlsym(h, "_ZN19SonyIaNativeDecoder6decodeEPhmm") != NULL &&
             dlsym(h, "_ZN19SonyIaNativeDecoder11setCoefPathEPKcS1_S1_") != NULL;
    if (!ok) snprintf(g_probe_err, sizeof(g_probe_err), "missing decoder symbols");
    dlclose(h);
    return ok ? 1 : 0;
}

/*
 * 阶段 1：创建 decoder 并注入系数路径。
 *   app_root   系数根目录（绝对路径，末尾带 / 与否皆可）
 *   config_rel config 文件相对路径（内容=hki 相对路径行）
 *   cp_rel     cp 文件相对路径（可为空串，缺文件不阻塞）
 *   spk_rel    扬声器参数相对路径（可为空串，空则不注入）
 * 返回 0 成功；-1 dlopen/符号缺失；-2 create 失败；-3 setCoef 缺符号。
 */
int ra360glue_init(const char *app_root, const char *config_rel,
                   const char *cp_rel, const char *spk_rel)
{
    if (g_dec) return 0; /* 进程内复用单实例 */
    g_lib = dlopen("qm_native_decoder_360ra.so", RTLD_NOW | RTLD_LOCAL);
    if (!g_lib) {
        LOGE("dlopen 360ra: %s", dlerror());
        return -1;
    }
    FnCreate create = (FnCreate)dlsym(g_lib, "create_SonyIaNativeDecoder");
    FnDestroy destroy = (FnDestroy)dlsym(g_lib, "destroy_SonyIaNativeDecoder");
    FnInit init = (FnInit)dlsym(g_lib, "_ZN19SonyIaNativeDecoder4initEP11IDataSource");
    g_decode = (FnDecode)dlsym(g_lib, "_ZN19SonyIaNativeDecoder6decodeEPhmm");
    g_getMinBuf = (FnIntFn)dlsym(g_lib, "_ZN19SonyIaNativeDecoder16getMinBufferSizeEv");
    FnIntFn getErr = (FnIntFn)dlsym(g_lib, "_ZN19SonyIaNativeDecoder16getDetailErrCodeEv");
    FnSetCoef setCoef = (FnSetCoef)dlsym(g_lib, "_ZN19SonyIaNativeDecoder11setCoefPathEPKcS1_S1_");
    FnSetSpk setSpk = (FnSetSpk)dlsym(g_lib, "_ZN19SonyIaNativeDecoder14setSpkFilePathEPKc");
    if (!create || !destroy || !init || !g_decode || !setCoef) {
        LOGE("missing decoder symbols");
        return -1;
    }
    (void)destroy; (void)getErr;

    g_dec = create();
    if (!g_dec) { LOGE("create failed"); return -2; }

    setCoef(g_dec, app_root, config_rel, cp_rel ? cp_rel : "");
    if (setSpk && spk_rel && spk_rel[0]) setSpk(g_dec, spk_rel);
    /* QEMU 逆向验证：decoder 实例偏移 +48（mSpkFilePath）在 glibc 适配版
     * 上残留垃圾值会导致 init 解引用崩溃/失败，显式清零（与官方 harness
     * 成功形态一致）。bionic 原版构造器是否初始化未知，清零无害。 */
    *(void **)((char *)g_dec + 48) = NULL;
    LOGI("decoder created, coef=%s/%s", app_root, config_rel);
    return 0;
}

/*
 * 阶段 2：打开 MHA1 mp4（RA01-04 原始流）。
 * 返回 0 成功；-10 未 init；-11 文件打不开；-12 init 失败（错误码见 getDetailErrCode）。
 */
int ra360glue_open(const char *mp4_path)
{
    if (!g_dec) return -10;
    ra360glue_close();
    g_ds = new FileDS();
    g_ds->path = mp4_path;
    g_ds->fp = fopen(mp4_path, "rb");
    if (!g_ds->fp) { LOGE("open %s", mp4_path); return -11; }
    g_ds->open(); /* 与官方调用形态一致：init 前 IDataSource 先 open */
    FnInit init = (FnInit)dlsym(g_lib, "_ZN19SonyIaNativeDecoder4initEP11IDataSource");
    int rc = init(g_dec, g_ds);
    if (rc != 0) {
        LOGE("init rc=%d", rc);
        return -12;
    }
    g_minbuf = g_getMinBuf ? g_getMinBuf(g_dec) : 0x2000;
    if (g_minbuf <= 0) g_minbuf = 0x2000;
    LOGI("open ok, minBufferSize=%d", g_minbuf);
    return 0;
}

/*
 * 阶段 3：全曲解码 → 48kHz/32bit/2ch WAV。
 * progress(pct, user)：0~100；传 NULL 忽略。
 * 返回 0 成功；-20 状态错；-21 wav 打不开；-22 解码零输出（首错码为负）。
 */
int ra360glue_decode_to_wav(const char *wav_path,
                            void (*progress)(int, void *), void *user)
{
    if (!g_dec || !g_decode || g_minbuf <= 0) return -20;
    FILE *w = fopen(wav_path, "wb");
    if (!w) { LOGE("wav open %s", wav_path); return -21; }
    wav_write_header(w, 0);

    unsigned char *buf = (unsigned char *)malloc((size_t)g_minbuf);
    if (!buf) { fclose(w); return -21; }

    long total = 0;
    int empty_run = 0;
    int last_pct = -1;
    int first_err = 0;
    for (int i = 0; i < 200000; i++) {
        long n = g_decode(g_dec, buf, 0, (unsigned long)g_minbuf);
        if (n > 0) {
            fwrite(buf, 1, (size_t)n, w);
            total += n;
            empty_run = 0;
        } else if (n < 0) {
            if (!first_err) {
                FnIntFn getErr = (FnIntFn)dlsym(g_lib, "_ZN19SonyIaNativeDecoder16getDetailErrCodeEv");
                first_err = getErr ? getErr(g_dec) : (int)n;
                LOGW("decode stop at loop %d, err=%d, total=%ld", i, first_err, total);
            }
            break; /* 负值 = EOF/错误，终止 */
        } else {
            if (++empty_run > 4096) { LOGW("too many empty reads"); break; }
        }
        if (progress && i % 64 == 0) {
            /* 帧数不可预知，进度按循环序号近似（每帧 8192B ≈ 1024*2*4） */
            int pct = (int)((total >> 23) & 0x7F); /* 0~127 → 供上层平滑 */
            if (pct != last_pct) { last_pct = pct; progress(pct, user); }
        }
    }
    free(buf);
    LOGI("decoded total=%ld bytes", total);
    if (total <= 0) { fclose(w); return -22; }
    unsigned int dsz = (unsigned int)total;
    wav_write_header(w, dsz);
    fclose(w);
    if (progress) progress(100, user);
    return 0;
}

void ra360glue_close(void)
{
    if (g_ds) {
        if (g_ds->fp) fclose(g_ds->fp);
        delete g_ds;
        g_ds = NULL;
    }
}

void ra360glue_release(void)
{
    ra360glue_close();
    if (g_lib) {
        FnDestroy destroy = (FnDestroy)dlsym(g_lib, "destroy_SonyIaNativeDecoder");
        if (destroy && g_dec) destroy(g_dec);
        dlclose(g_lib);
        g_lib = NULL;
        g_dec = NULL;
        g_decode = NULL;
        g_getMinBuf = NULL;
        g_minbuf = 0;
    }
}

} /* extern "C" */
