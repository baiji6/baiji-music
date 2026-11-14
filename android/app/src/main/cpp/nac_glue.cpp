/*
 * nac_glue.cpp — baiji-music QQ 音乐 NAC（TL01）神经音频解码原生模块
 *
 * NAC = QQ 音乐自研 Neural Audio Codec。码流里存的既不是 PCM 也不是频域
 * 数据，而是矢量量化码字（codes）—— 必须经神经网络模型前向推理才能
 * 重建复数频谱，再由 ISTFT 还原波形。
 *
 * 链路（全部自研实现，不依赖 tmecodec 私有 ABI）：
 *   NAC 容器解析 → 10bit codes 解包 → MNN 推理（流式 buffer 回灌）
 *     → 复数谱 freq → ISTFT（Hann 512 / hop 256 / OLA 归一化）→ WAV
 *
 * 输出：44100Hz / 16-bit int / 立体声交错 PCM（软限幅后量化）。
 *
 * 依赖：仅 QQ 音乐 CDN 下发的 `libMNN_dl.so`（arm64-v8a；Apache-2.0 的
 * MNN 推理引擎，内部静态链接全部依赖、UND 符号为 0）。这里通过 dlsym
 * 直接调用其导出的 C++ 符号，既不链接也不需要 MNN 头文件。
 *
 * 不直接引用 std::string / std::map 等 STL 类型：glue 只构造全零的
 * ScheduleConfig 并把 const char* 传给 getSessionInput/getSessionOutput，
 * 因此不依赖宿主的 STL 布局（便于在 QEMU/glibc 下交叉验证）。
 *
 * 格式规格（经官方 Demuxer 交叉验证，详见 /workspace/nac-research）：
 *   容器头：magic "NAC_"(4B) + f32(4B) + u16(2B) + 5B + JSON 元数据(93B) = 108B
 *   载荷  ：nseg 段 × stride 1764B（= 1760B codes 位流 + 4B 段尾）
 *   位流  ：LSB-first 连续位流，每码 10 bit；
 *           读取顺序 [ch][frame][cb] → 存储布局 [ch][cb][frame]（必须转置）
 *   模型  ：输入 codes(2,22,32) int32 + 6 个流式 buffer；
 *           输出 freq(2,2,34,257)，第 0、33 帧恒为 0（padding），
 *           有效帧为 1..32；相邻段的重叠由模型自身负责，逐段拼接即无缝。
 *
 * 内存：ISTFT 用滑动窗口增量写出，常驻约 68KB，与曲长无关。
 *
 * C API（Dart FFI 见 lib/nac/nac_decoder.dart）：
 *   int  nacglue_abi_available(void)                   引擎自检（含推理烟测）
 *   const char *nacglue_probe_detail(void)             自检失败详情
 *   int  nacglue_init(const char *model_path)          加载模型、建 session
 *   int  nacglue_open(const char *nac_path)            打开 .nac 容器
 *   int  nacglue_decode_to_wav(wav, progress, user)   全曲解码 → WAV
 *   void nacglue_close(void)                           关闭当前曲目
 *   void nacglue_release(void)                         释放模型与 session
 */
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <cmath>
#include <string>
#include <vector>

#ifdef __ANDROID__
#include <unistd.h>  /* sysconf(_SC_NPROCESSORS_ONLN) —— 多核加速 MNN 推理 */
#endif

#ifdef __ANDROID__
#include <android/log.h>
#define TAG "nac_glue"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
#else
#define LOGI(...)                                                              \
    do {                                                                       \
        fprintf(stderr, "[nac_glue] ");                                        \
        fprintf(stderr, __VA_ARGS__);                                         \
        fprintf(stderr, "\n");                                                 \
    } while (0)
#define LOGW LOGI
#define LOGE LOGI
#endif

/* ===================== 常量 ===================== */

#define NAC_MAGIC "NAC_"
#define NAC_MAX_SEG 8192
#define NAC_MAX_CH 8

/* MNN dl 接口函数表下标（libMNN_dl.so 反汇编确认） */
enum { IDX_NET_INIT = 0, IDX_NET_FORWARD = 2, IDX_NET_RELEASE_SESSION = 11 };

/* tensor 函数表下标 */
enum {
    IDX_T_SHAPE = 5,
    IDX_T_COPY_FROM_BUF = 7,
    IDX_T_COPY_TO_BUF = 8
};

/* MNNTensorType：net_tensor2 第 3 参数 */
#define MNN_TENSOR_INPUT 0
#define MNN_TENSOR_OUTPUT 1

/* libc++ SSO 短串容量（64 位，char） */
#define SSO_CAP 22
#define SSO_SIZE 24

/* ===================== 类型定义 ===================== */

/*
 * MNN::ScheduleConfig（libc++ 布局）—— 按 MNN 3.1.3 头文件推导：
 *   +0  std::vector<std::string> saveTensors   (3 ptr = 24B)
 *   +24 MNNForwardType type                    (int)
 *   +28 int numThread                          (int)
 *   +32 Path::inputs  (std::vector<std::string>, 24B)
 *   +56 Path::outputs (std::vector<std::string>, 24B)
 *   +80 Path::mode    (int)
 *   +88 MNNForwardType backupType              (int)
 *   +96 BackendConfig* backendConfig           (ptr)
 * 合计 104B；这里分配 128B 并只在 +28 写线程数，其余全零，等价于默认构造。
 */
struct MNNScheduleConfig {
    char raw[128];
};

/* ===================== 容器头 ===================== */

struct NacHeader {
    int sampleRate = 44100;
    int channels = 2;
    int fft = 512;
    int hop = 256;
    int nseg = 0;
    int nf = 32;
    int cn = 22;
    int cb = 10;
    int stride = 1764;
    int dataBytes = 1760;
    size_t payloadOff = 0;
    size_t payloadSize = 0;
};

/* ===================== 全局状态 ===================== */

static void *g_lib = NULL;
static void *g_interp = NULL;
static void *g_sess = NULL;
static char g_probe_err[512];

/* MNN 函数指针
 *
 * Interpreter / Session 走 **导出的 C++ 符号**（dlsym 按 mangled 名取）。
 * 注意 net_* 系列（net_init 等）是另一套「dl 函数表」接口，二者不可混用：
 * 函数表里没有 createFromFile，而 getSessionInput/getSessionOutput 恰好
 * 直接接收 const char*，正好绕开 STL 布局依赖。
 *
 * Tensor 的数据读写走 tensor 函数表（copyFromBuffer / copyToBuffer），
 * 纯指针操作，同样不依赖 STL。 */
typedef void *(*FnCreateFromFile)(const char *);
typedef void *(*FnCreateSession)(void *, const void *);
typedef void *(*FnGetSessionTensor)(void *, const void *, const char *);
typedef int (*FnRunSession)(const void *, void *);
typedef void (*FnDestroy)(void *);
typedef void *(*FnGetTable)();
typedef void (*FnTensorCopyFrom)(void *, const void *, unsigned long);
typedef void (*FnTensorCopyTo)(const void *, void *, unsigned long);

static FnCreateFromFile g_createFromFile = NULL;
static FnCreateSession g_createSession = NULL;
static FnGetSessionTensor g_getInput = NULL;
static FnGetSessionTensor g_getOutput = NULL;
static FnRunSession g_runSession = NULL;
static FnDestroy g_destroy = NULL;
static FnTensorCopyFrom g_copyFromBuf = NULL;
static FnTensorCopyTo g_copyToBuf = NULL;
/* 符号是否已绑定成功（进程内只需一次） */
static int g_bindOk = 0;

/* 流式状态缓冲 */
struct BufSpec {
    const char *inName;
    const char *outName;
    int shape[4];
};

static const BufSpec kBufs[] = {
    {"buffer_conv_0", "out_buffer_conv_0", {2, 42, 2, 34}},
    {"buffer_conv_1", "out_buffer_conv_1", {2, 21, 2, 130}},
    {"buffer_conv_2", "out_buffer_conv_2", {2, 10, 2, 258}},
    {"buffer_res_0", "out_buffer_res_0", {2, 42, 1, 32}},
    {"buffer_res_1", "out_buffer_res_1", {2, 21, 1, 128}},
    {"buffer_res_2", "out_buffer_res_2", {2, 10, 1, 256}},
};
static const int kNBuf = (int)(sizeof(kBufs) / sizeof(kBufs[0]));

static NacHeader g_hdr;
static std::vector<uint8_t> g_payload;
static std::vector<std::vector<float>> g_state;

/* ===================== 工具 ===================== */

static void setErr(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_probe_err, sizeof(g_probe_err), fmt, ap);
    va_end(ap);
}

/* 构造 libc++ SSO 短串（小端：b[0] = size<<1，数据从 b[1] 开始，NUL 结尾） */
static void mkSSO(char *b, const char *s) {
    size_t n = strlen(s);
    memset(b, 0, SSO_SIZE);
    if (n <= SSO_CAP) {
        b[0] = (char)(n << 1);
        memcpy(b + 1, s, n);
        b[n + 1] = 0;
    } else {
        /* 长串：{ cap|1, size, ptr } —— 名字均不超过 22B，正常走不到这里 */
        *(size_t *)(b + 0) = ((n + 1) << 1) | 1;
        *(size_t *)(b + 8) = n;
        *(char **)(b + 16) = (char *)s;
    }
}

/* 极简 JSON 取值：读取 key 后的第一个整数（只为解析容器头的少量字段） */
static bool jsonGetInt(const std::string &s, const std::string &key, int *out) {
    size_t p = 0;
    while (true) {
        size_t k = s.find("\"" + key + "\"", p);
        if (k == std::string::npos) return false;
        size_t c = s.find(':', k);
        if (c == std::string::npos) return false;
        size_t v = c + 1;
        while (v < s.size() && (s[v] == ' ' || s[v] == '\t')) v++;
        bool neg = (v < s.size() && s[v] == '-');
        if (neg) v++;
        long long val = 0;
        bool any = false;
        while (v < s.size() && s[v] >= '0' && s[v] <= '9') {
            val = val * 10 + (s[v] - '0');
            v++;
            any = true;
        }
        if (any) {
            *out = (int)(neg ? -val : val);
            return true;
        }
        p = c + 1; /* 该 key 非整数，继续找同名 key */
    }
}

/* 容器解析：magic → JSON 头 → 载荷 */
static bool parseContainer(const char *path, NacHeader *h) {
    FILE *f = fopen(path, "rb");
    if (!f) return false;

    std::vector<uint8_t> head(4096);
    size_t got = fread(head.data(), 1, head.size(), f);
    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (got < 16 || fsize <= 0) { fclose(f); return false; }
    if (memcmp(head.data(), NAC_MAGIC, 4) != 0) { fclose(f); return false; }

    size_t js = 0;
    while (js < got && head[js] != '{') js++;
    if (js >= got) { fclose(f); return false; }

    size_t je = js;
    int depth = 0;
    bool instr = false, esc = false;
    for (size_t i = js; i < got; i++) {
        char c = (char)head[i];
        if (esc) { esc = false; continue; }
        if (c == '\\') { esc = true; continue; }
        if (c == '"') { instr = !instr; continue; }
        if (instr) continue;
        if (c == '{') depth++;
        else if (c == '}') { depth--; if (depth == 0) { je = i; break; } }
    }
    if (je <= js) { fclose(f); return false; }

    std::string json((const char *)head.data() + js, je - js + 1);
    jsonGetInt(json, "sr", &h->sampleRate);
    jsonGetInt(json, "ch", &h->channels);
    jsonGetInt(json, "fft", &h->fft);
    jsonGetInt(json, "hop", &h->hop);
    jsonGetInt(json, "tf", &h->nseg);
    jsonGetInt(json, "nf", &h->nf);
    jsonGetInt(json, "cn", &h->cn);
    jsonGetInt(json, "cb", &h->cb);

    int codesPerCh = h->cn * h->nf;               /* 704 */
    int bits = codesPerCh * h->cb * h->channels;  /* 14080 */
    h->dataBytes = (bits + 7) / 8;                 /* 1760 */
    h->stride = h->dataBytes + 4;                   /* 1764 */

    h->payloadOff = je + 1;
    if ((long)h->payloadOff >= fsize) { fclose(f); return false; }
    h->payloadSize = (size_t)fsize - h->payloadOff;
    h->nseg = (int)(h->payloadSize / (size_t)h->stride);
    if (h->nseg <= 0) { fclose(f); return false; }
    if (h->nseg > NAC_MAX_SEG) h->nseg = NAC_MAX_SEG;
    if (h->channels <= 0 || h->channels > NAC_MAX_CH) { fclose(f); return false; }
    if (h->nf <= 0 || h->cn <= 0 || h->cb <= 0 || h->fft <= 0 || h->hop <= 0) {
        fclose(f);
        return false;
    }

    g_payload.resize((size_t)h->nseg * (size_t)h->stride);
    fseek(f, (long)h->payloadOff, SEEK_SET);
    size_t rd = fread(g_payload.data(), 1, g_payload.size(), f);
    fclose(f);
    return rd == g_payload.size();
}

/*
 * 段 → codes[ch][cb][frame]。
 * 严格复刻 x86 验证管线：LSB-first 位流，读取序 [ch][frame][cb]，
 * 存储序 [ch][cb][frame]（转置）。
 */
static void unpackSegment(const uint8_t *seg, int32_t *out,
                          const NacHeader &h) {
    const int CN = h.cn, NF = h.nf, CH = h.channels, CB = h.cb;
    const int codesPerCh = CN * NF;   /* 704 */

    int bitpos = 0;
    for (int ch = 0; ch < CH; ch++) {
        for (int fr = 0; fr < NF; fr++) {
            for (int cb = 0; cb < CN; cb++) {
                int v = 0;
                for (int b = 0; b < CB; b++) {
                    int p = bitpos + b;
                    int bit = (seg[p >> 3] >> (p & 7)) & 1;
                    v |= bit << b;   /* LSB-first */
                }
                bitpos += CB;
                out[ch * codesPerCh + cb * NF + fr] = v;
            }
        }
    }
}

/* ===================== FFT（radix-2，512 点 IFFT） ===================== */

static void fftRadix2(float *re, float *im, int n, bool inverse) {
    for (int i = 1, j = 0; i < n; i++) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            float tr = re[i], ti = im[i];
            re[i] = re[j]; im[i] = im[j];
            re[j] = tr; im[j] = ti;
        }
    }
    for (int len = 2; len <= n; len <<= 1) {
        double ang = 2.0 * M_PI / (double)len * (inverse ? 1.0 : -1.0);
        float wr = (float)std::cos(ang), wi = (float)std::sin(ang);
        for (int i = 0; i < n; i += len) {
            float cr = 1.0f, ci = 0.0f;
            for (int k = 0; k < len / 2; k++) {
                int a = i + k, b = a + len / 2;
                float ur = re[a], ui = im[a];
                float vr = re[b] * cr - im[b] * ci;
                float vi = re[b] * ci + im[b] * cr;
                re[a] = ur + vr; im[a] = ui + vi;
                re[b] = ur - vr; im[b] = ui - vi;
                float ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
        }
    }
    if (inverse) {
        for (int i = 0; i < n; i++) { re[i] /= (float)n; im[i] /= (float)n; }
    }
}

/* ===================== WAV 写出 ===================== */

static void put32(FILE *f, uint32_t v) { fwrite(&v, 4, 1, f); }
static void put16(FILE *f, uint16_t v) { fwrite(&v, 2, 1, f); }

static void wavWriteHeader(FILE *f, uint32_t dataBytes, int sampleRate, int ch) {
    fseek(f, 0, SEEK_SET);
    fwrite("RIFF", 1, 4, f);
    put32(f, 36 + dataBytes);
    fwrite("WAVEfmt ", 1, 8, f);
    put32(f, 16);
    put16(f, (uint16_t)1); /* PCM */
    put16(f, (uint16_t)ch);
    put32(f, (uint32_t)sampleRate);
    put32(f, (uint32_t)(sampleRate * ch * 2));
    put16(f, (uint16_t)(ch * 2));
    put16(f, (uint16_t)16);
    fwrite("data", 1, 4, f);
    put32(f, dataBytes);
}

/* 软限幅：knee 以下 1:1 通过，以上 tanh 压缩，避免硬 clip 失真 */
static double softClip(double v) {
    const double knee = 0.85;
    if (v > knee)
        return knee + (1.0 - knee) * std::tanh((v - knee) / (1.0 - knee));
    if (v < -knee)
        return -(knee + (1.0 - knee) * std::tanh((-v - knee) / (1.0 - knee)));
    return v;
}

/* ===================== MNN dl 接口绑定 ===================== */

static int mnnLoad() {
    if (g_lib) return 0;
    g_lib = dlopen("libMNN_dl.so", RTLD_NOW | RTLD_LOCAL);
    if (!g_lib) {
        const char *e = dlerror();
        setErr("dlopen libMNN_dl.so: %s", e ? e : "unknown");
        return -1;
    }
    return 0;
}

/* ===================== 对外 API（Dart FFI，C 导出） ===================== */

extern "C" {

void nacglue_close(void);

const char *nacglue_probe_detail(void) {
    return g_probe_err[0] ? g_probe_err : "ok";
}

/*
 * 绑定 MNN 符号：dlopen 官方库 + dlsym 取所需符号。
 * 不加载模型、不涉及任何外部配置，失败详情写入 g_probe_err。
 * 返回 0 成功；-1 dlopen 失败；-2 符号缺失。
 */
static int mnnBind() {
    if (g_bindOk) return 0;
    if (mnnLoad() != 0) return -1;

    typedef void *(*FnGetTbl)();
    FnGetTbl getT = (FnGetTbl)dlsym(g_lib, "MNNGetTensorFunc");
    if (!getT) {
        setErr("missing MNNGetTensorFunc");
        return -2;
    }

    /* Interpreter / Session：直接取导出的 C++ 符号 */
    g_createFromFile = (FnCreateFromFile)dlsym(
        g_lib, "_ZN3MNN11Interpreter14createFromFileEPKc");
    g_createSession = (FnCreateSession)dlsym(
        g_lib, "_ZN3MNN11Interpreter13createSessionERKNS_14ScheduleConfigE");
    g_getInput = (FnGetSessionTensor)dlsym(
        g_lib, "_ZN3MNN11Interpreter15getSessionInputEPKNS_7SessionEPKc");
    g_getOutput = (FnGetSessionTensor)dlsym(
        g_lib, "_ZN3MNN11Interpreter16getSessionOutputEPKNS_7SessionEPKc");
    g_runSession = (FnRunSession)dlsym(
        g_lib, "_ZNK3MNN11Interpreter10runSessionEPNS_7SessionE");
    g_destroy = (FnDestroy)dlsym(g_lib, "_ZN3MNN11Interpreter7destroyEPS0_");

    /* Tensor 数据读写：tensor 函数表（纯指针操作） */
    void **TT = (void **)getT();
    if (TT) {
        g_copyFromBuf = (FnTensorCopyFrom)TT[IDX_T_COPY_FROM_BUF];
        g_copyToBuf = (FnTensorCopyTo)TT[IDX_T_COPY_TO_BUF];
    }

    if (!g_createFromFile || !g_createSession || !g_runSession ||
        !g_getInput || !g_getOutput || !g_copyFromBuf || !g_copyToBuf) {
        setErr("missing MNN symbols (create/session/tensor)");
        return -2;
    }
    g_bindOk = 1;
    return 0;
}

/*
 * 加载模型并建立推理 session。
 * 返回 0 成功；-1 路径为空；-2 库/符号不可用；-3 创建失败。
 */
int nacglue_init(const char *model_path) {
    if (g_sess) return 0;
    if (!model_path || !model_path[0]) return -1;
    if (mnnBind() != 0) return -2;

    /* ScheduleConfig：全零 + CPU 后端 + 多线程。
     * numThread 写在 +28 字段。旧实现写死 4，在多核设备上严重亏待推理吞吐；
     * 这里按在线 CPU 核数自适应（封顶 8、保底 2），单核设备退化为 4 兜底。
     * MNN 对超额订阅有内部调度，核数写大不会崩，只是略增开销。 */
    MNNScheduleConfig cfg;
    memset(&cfg, 0, sizeof cfg);
    int numThread = 4;
#ifdef __ANDROID__
    long np = sysconf(_SC_NPROCESSORS_ONLN);
    if (np > 0) {
        numThread = (int)np;
        if (numThread > 8) numThread = 8;
        if (numThread < 2) numThread = 2;
    }
#endif
    *(int *)(cfg.raw + 28) = numThread;

    void *interp = g_createFromFile(model_path);
    LOGI("createFromFile(%s) -> %p", model_path, interp);
    if (!interp) {
        setErr("createFromFile returned null");
        return -3;
    }
    void *sess = g_createSession(interp, &cfg);
    LOGI("createSession -> %p", sess);
    if (!sess) {
        setErr("createSession returned null");
        if (g_destroy) g_destroy(interp);
        return -3;
    }
    g_interp = interp;
    g_sess = sess;

    /* 流式状态缓冲初始化（首轮全零） */
    g_state.clear();
    g_state.reserve((size_t)kNBuf);
    for (int i = 0; i < kNBuf; i++) {
        size_t n = (size_t)kBufs[i].shape[0] * (size_t)kBufs[i].shape[1] *
                    (size_t)kBufs[i].shape[2] * (size_t)kBufs[i].shape[3];
        g_state.push_back(std::vector<float>(n, 0.0f));
    }
    LOGI("model ready: %s", model_path);
    return 0;
}

/*
 * 引擎自检（App 用）：只确认 libMNN_dl.so 可加载、所需符号齐全。
 *
 * 刻意**不加载模型、不读环境变量**——模型的真实路径来自 App 把 assets
 * 解包到私有目录的结果（<cache>/nac/7187332.mnn），而本函数在启动阶段
 * 就会被调用，那时路径还没算出来。早期版本用 getenv("NAC_MODEL_PATH")
 * 兜底，结果 App 里没人设置它，探测恒为 0，NAC 档被静默降级。
 * 模型缺失/损坏由 nacglue_init 在真正解码时报错，走同样的降级链。
 */
int nacglue_abi_available(void) {
    if (g_sess) return 1;
    if (mnnBind() != 0) return 0;
    LOGI("engine self-check passed (symbols ok)");
    return 1;
}

/*
 * 完整自检（工具 / 测试用）：在引擎可用的基础上再加载模型、建 session、
 * 跑一次零输入推理，需要显式给出模型路径。App 不需要调用它。
 */
int nacglue_probe(const char *model_path) {
    if (nacglue_abi_available() != 1) return 0;
    if (!model_path || !model_path[0]) {
        setErr("nacglue_probe: empty model path");
        return 0;
    }
    if (nacglue_init(model_path) != 0) return 0;

    /* 烟测：喂零 codes，确认整图可跑通且能取到 freq（name 为 C 串） */
    void *tCodes = g_getInput(g_interp, g_sess, "codes");
    void *tFreq = g_getOutput(g_interp, g_sess, "freq");
    if (!tCodes || !tFreq) {
        setErr("smoke: missing codes/freq tensor");
        return 0;
    }
    if (g_runSession(g_interp, g_sess) != 0) {
        setErr("smoke: runSession failed");
        return 0;
    }
    LOGI("full self-check passed (model + inference ok)");
    return 1;
}

/*
 * 打开 .nac 容器并解析头信息。
 * 返回 0 成功；-10 未 init；-11 打不开/格式错；-12 无有效段。
 */
int nacglue_open(const char *nac_path) {
    if (!g_sess) return -10;
    nacglue_close();
    NacHeader h;
    if (!parseContainer(nac_path, &h)) {
        LOGE("container parse failed: %s", nac_path);
        return -11;
    }
    if (h.nseg <= 0) {
        LOGE("no segments");
        return -12;
    }
    g_hdr = h;
    LOGI("open ok: sr=%d ch=%d fft=%d hop=%d segs=%d stride=%d",
         h.sampleRate, h.channels, h.fft, h.hop, h.nseg, h.stride);
    return 0;
}

/*
 * 全曲解码 → 44100Hz/16bit/立体声 WAV（流式增量写出，内存与曲长无关）。
 *
 * 每段喂 32 帧 codes，模型输出 34 帧复数谱（首尾各 1 帧 padding，恒为 0），
 * 取第 1..32 帧做 ISTFT。段间重叠 256 采样由 tail 缓冲衔接。
 *
 * progress(pct, user)：0~100，可传 NULL。
 * 返回 0 成功；-20 状态错；-21 wav 打不开；-22 推理失败或零输出。
 */
int nacglue_decode_to_wav(const char *wav_path,
                          void (*progress)(int, void *), void *user) {
    if (!g_sess || !g_interp) return -20;
    if (g_hdr.nseg <= 0 || g_hdr.channels <= 0) return -20;

    const int NF = g_hdr.nf;        /* 每段有效帧数 32 */
    const int HOP = g_hdr.hop;      /* 256 */
    const int NFFT = g_hdr.fft;     /* 512 */
    const int FR = 34;              /* 模型输出帧数（含 2 padding） */
    const int BINS = NFFT / 2 + 1;  /* 257 */
    const int CH = g_hdr.channels;
    const int CODE_N = g_hdr.cn * NF * CH;   /* 1408 */

    const int LEN = (NF - 1) * HOP + NFFT;  /* 8448 本段 OLA 跨度 */
    const int EMIT = NF * HOP;              /* 8192 可定稿长度 */
    const int TAIL = LEN - EMIT;            /* 256 需与下段重叠 */

    /* 张量句柄：只在首段查询一次，后续复用。
     * getSessionInput/getSessionOutput 的第二参数是 const char*（C 串），
     * 不经过 std::string，因此不受 STL 布局差异影响。 */
    void *tCodes = g_getInput(g_interp, g_sess, "codes");
    void *tFreq = g_getOutput(g_interp, g_sess, "freq");
    if (!tCodes || !tFreq) {
        setErr("missing tensor codes/freq");
        return -22;
    }

    void *tIn[(sizeof(kBufs) / sizeof(kBufs[0]))];
    void *tOut[(sizeof(kBufs) / sizeof(kBufs[0]))];
    for (int i = 0; i < kNBuf; i++) {
        tIn[i] = g_getInput(g_interp, g_sess, kBufs[i].inName);
        tOut[i] = g_getOutput(g_interp, g_sess, kBufs[i].outName);
    }

    FILE *w = fopen(wav_path, "wb");
    if (!w) {
        LOGE("wav open: %s", wav_path);
        return -21;
    }
    uint8_t hdr44[44];
    memset(hdr44, 0, sizeof hdr44);
    fwrite(hdr44, 1, sizeof hdr44, w);

    /* Hann 窗（对称，与 np.hanning(512) 一致） */
    std::vector<float> win((size_t)NFFT);
    for (int i = 0; i < NFFT; i++)
        win[(size_t)i] = (float)(0.5 - 0.5 * std::cos(2.0 * M_PI * i / (NFFT - 1)));

    std::vector<int32_t> codes((size_t)CODE_N);
    std::vector<float> Xr((size_t)NFFT), Xi((size_t)NFFT);
    std::vector<float> freqBuf((size_t)CH * 2 * FR * BINS);

    std::vector<double> acc((size_t)LEN, 0.0);
    std::vector<double> nrm((size_t)LEN, 0.0);
    std::vector<std::vector<double>> carry((size_t)CH,
                                            std::vector<double>((size_t)TAIL, 0.0));
    std::vector<std::vector<double>> carryN((size_t)CH,
                                             std::vector<double>((size_t)TAIL, 0.0));
    std::vector<int16_t> inter((size_t)EMIT * (size_t)CH);

    long totalSamples = 0;
    int last_pct = -1;

    for (int s = 0; s < g_hdr.nseg; s++) {
        const uint8_t *seg = g_payload.data() + (size_t)s * (size_t)g_hdr.stride;
        unpackSegment(seg, codes.data(), g_hdr);

        /* 输入：codes + 6 个流式状态 */
        g_copyFromBuf(tCodes, codes.data(),
                      (unsigned long)((size_t)CODE_N * 4));
        for (int i = 0; i < kNBuf; i++) {
            if (tIn[i])
                g_copyFromBuf(tIn[i], g_state[i].data(),
                              (unsigned long)(g_state[i].size() * sizeof(float)));
        }

        if (g_runSession(g_interp, g_sess) != 0) {
            LOGE("runSession failed at seg %d", s);
            fclose(w);
            return -22;
        }

        /* 输出：freq 复数谱 + 更新后的流式状态 */
        g_copyToBuf(tFreq, freqBuf.data(),
                    (unsigned long)(freqBuf.size() * sizeof(float)));
        for (int i = 0; i < kNBuf; i++) {
            if (tOut[i])
                g_copyToBuf(tOut[i], g_state[i].data(),
                            (unsigned long)(g_state[i].size() * sizeof(float)));
        }

        /*
         * 本段 ISTFT：有效帧 1..32（freq 布局 [ch][re:im][frame][bin]）。
         * 每帧构造共轭对称谱后 IFFT，乘窗后按 hop 重叠相加。
         */
        for (int ch = 0; ch < CH; ch++) {
            std::fill(acc.begin(), acc.end(), 0.0);
            std::fill(nrm.begin(), nrm.end(), 0.0);
            for (int f = 1; f <= NF; f++) {
                const float *re = freqBuf.data() + ((size_t)ch * 2 * FR + f) * BINS;
                const float *im = freqBuf.data() + ((size_t)ch * 2 * FR + FR + f) * BINS;

                for (int n = 0; n < NFFT; n++) { Xr[(size_t)n] = 0.0f; Xi[(size_t)n] = 0.0f; }
                for (int k = 0; k < BINS; k++) {
                    Xr[(size_t)k] = re[k];
                    Xi[(size_t)k] = im[k];
                    if (k > 0 && k < NFFT / 2) {
                        Xr[(size_t)(NFFT - k)] =  re[k];
                        Xi[(size_t)(NFFT - k)] = -im[k];
                    }
                }
                fftRadix2(Xr.data(), Xi.data(), NFFT, /*inverse=*/true);

                const int off = (f - 1) * HOP;
                for (int n = 0; n < NFFT; n++) {
                    acc[(size_t)(off + n)] += (double)Xr[(size_t)n] * (double)win[(size_t)n];
                    nrm[(size_t)(off + n)] += (double)win[(size_t)n];
                }
            }

            /* 叠加跨段残余（作用于本段开头 TAIL 个采样） */
            for (int i = 0; i < TAIL; i++) {
                acc[(size_t)i] += carry[(size_t)ch][(size_t)i];
                nrm[(size_t)i] += carryN[(size_t)ch][(size_t)i];
            }

            /* 定稿前 EMIT 个采样，交错写入 */
            for (long i = 0; i < EMIT; i++) {
                double v = (nrm[(size_t)i] > 1e-6) ? acc[(size_t)i] / nrm[(size_t)i] : 0.0;
                v = softClip(v);
                double q = v * 32767.0;
                if (q > 32767.0) q = 32767.0;
                if (q < -32768.0) q = -32768.0;
                inter[(size_t)(i * CH + ch)] = (int16_t)(q >= 0 ? q + 0.5 : q - 0.5);
            }

            /* 更新残余 = 本段尾部 TAIL 个采样 */
            for (int i = 0; i < TAIL; i++) {
                carry[(size_t)ch][(size_t)i]  = acc[(size_t)(EMIT + i)];
                carryN[(size_t)ch][(size_t)i] = nrm[(size_t)(EMIT + i)];
            }
        }

        fwrite(inter.data(), 1, inter.size() * 2, w);
        totalSamples += EMIT;

        if (progress) {
            int pct = (int)((s + 1) * 100 / g_hdr.nseg);
            if (pct != last_pct) { last_pct = pct; progress(pct, user); }
        }
    }

    /* 收尾：写出最后一段的残余 */
    for (int i = 0; i < TAIL; i++) {
        for (int ch = 0; ch < CH; ch++) {
            double v = (carryN[(size_t)ch][(size_t)i] > 1e-6)
                           ? carry[(size_t)ch][(size_t)i] / carryN[(size_t)ch][(size_t)i]
                           : 0.0;
            v = softClip(v);
            double q = v * 32767.0;
            if (q > 32767.0) q = 32767.0;
            if (q < -32768.0) q = -32768.0;
            inter[(size_t)(i * CH + ch)] = (int16_t)(q >= 0 ? q + 0.5 : q - 0.5);
        }
    }
    fwrite(inter.data(), 1, (size_t)TAIL * (size_t)CH * 2, w);
    totalSamples += TAIL;

    wavWriteHeader(w, (uint32_t)((size_t)totalSamples * (size_t)CH * 2),
                   g_hdr.sampleRate, CH);
    fclose(w);

    if (progress) progress(100, user);
    LOGI("decoded segs=%d -> %ld samples (%ld bytes)", g_hdr.nseg, totalSamples,
         totalSamples * (long)CH * 2);
    return 0;
}

void nacglue_close(void) {
    g_payload.clear();
    g_hdr = NacHeader();
    /* 流式状态复位，下首曲子从头开始 */
    for (size_t i = 0; i < g_state.size(); i++)
        std::fill(g_state[i].begin(), g_state[i].end(), 0.0f);
}

/* ===================== 流式解码（v2.5.8-fix2：边转码边播放） =====================
 *
 * NAC 一次解码要 1~2 分钟（MNN 神经推理 + ISTFT），整曲解码完才出声的
 * 体验很差。流式版本**边解边把 PCM 追加写到目标文件**，progress 回调
 * 通知已写字节数（-1 = 正常结束）；Dart 侧 tail 这个文件并推给本机
 * HttpServer → media_kit，播放器边收边播，首帧到达即出声。
 *
 * 采样率与声道数取自 .nac 容器头（g_hdr），解码前即已知，头可以一次写对。
 *
 * 文件格式：标准 44 字节 WAV 头，RIFF / data 长度写 0xFFFFFFFF（未知总长，
 * 流式场景的常规做法，ffmpeg / mpv 都能正常解码）。
 */
int nacglue_decode_stream(const char *wav_path,
                           void (*progress)(long, void *), void *user) {
    if (!g_sess || !g_interp) return -20;
    if (g_hdr.nseg <= 0 || g_hdr.channels <= 0) return -20;

    const int NF = g_hdr.nf;        /* 每段有效帧数 32 */
    const int HOP = g_hdr.hop;      /* 256 */
    const int NFFT = g_hdr.fft;     /* 512 */
    const int FR = 34;              /* 模型输出帧数（含 2 padding） */
    const int BINS = NFFT / 2 + 1;  /* 257 */
    const int CH = g_hdr.channels;
    const int CODE_N = g_hdr.cn * NF * CH;

    const int LEN = (NF - 1) * HOP + NFFT;
    const int EMIT = NF * HOP;              /* 8192 可定稿长度 */
    const int TAIL = LEN - EMIT;            /* 256 需与下段重叠 */

    void *tCodes = g_getInput(g_interp, g_sess, "codes");
    void *tFreq = g_getOutput(g_interp, g_sess, "freq");
    if (!tCodes || !tFreq) {
        setErr("missing tensor codes/freq");
        return -22;
    }

    void *tIn[(sizeof(kBufs) / sizeof(kBufs[0]))];
    void *tOut[(sizeof(kBufs) / sizeof(kBufs[0]))];
    for (int i = 0; i < kNBuf; i++) {
        tIn[i] = g_getInput(g_interp, g_sess, kBufs[i].inName);
        tOut[i] = g_getOutput(g_interp, g_sess, kBufs[i].outName);
    }

    FILE *w = fopen(wav_path, "wb");
    if (!w) {
        LOGE("wav open: %s", wav_path);
        return -21;
    }
    /* 流式头：长度字段全 0xFFFFFFFF（未知总长）。 */
    wavWriteHeader(w, 0xFFFFFFFFu, g_hdr.sampleRate, CH);

    /* Hann 窗（对称，与 np.hanning(512) 一致） */
    std::vector<float> win((size_t)NFFT);
    for (int i = 0; i < NFFT; i++)
        win[(size_t)i] = (float)(0.5 - 0.5 * std::cos(2.0 * M_PI * i / (NFFT - 1)));

    std::vector<int32_t> codes((size_t)CODE_N);
    std::vector<float> Xr((size_t)NFFT), Xi((size_t)NFFT);
    std::vector<float> freqBuf((size_t)CH * 2 * FR * BINS);

    std::vector<double> acc((size_t)LEN, 0.0);
    std::vector<double> nrm((size_t)LEN, 0.0);
    std::vector<std::vector<double>> carry((size_t)CH,
                                            std::vector<double>((size_t)TAIL, 0.0));
    std::vector<std::vector<double>> carryN((size_t)CH,
                                             std::vector<double>((size_t)TAIL, 0.0));
    std::vector<int16_t> inter((size_t)EMIT * (size_t)CH);

    long totalSamples = 0;

    for (int s = 0; s < g_hdr.nseg; s++) {
        const uint8_t *seg = g_payload.data() + (size_t)s * (size_t)g_hdr.stride;
        unpackSegment(seg, codes.data(), g_hdr);

        g_copyFromBuf(tCodes, codes.data(),
                      (unsigned long)((size_t)CODE_N * 4));
        for (int i = 0; i < kNBuf; i++) {
            if (tIn[i])
                g_copyFromBuf(tIn[i], g_state[i].data(),
                              (unsigned long)(g_state[i].size() * sizeof(float)));
        }

        if (g_runSession(g_interp, g_sess) != 0) {
            LOGE("runSession failed at seg %d", s);
            fclose(w);
            return -22;
        }

        g_copyToBuf(tFreq, freqBuf.data(),
                    (unsigned long)(freqBuf.size() * sizeof(float)));
        for (int i = 0; i < kNBuf; i++) {
            if (tOut[i])
                g_copyToBuf(tOut[i], g_state[i].data(),
                            (unsigned long)(g_state[i].size() * sizeof(float)));
        }

        for (int ch = 0; ch < CH; ch++) {
            std::fill(acc.begin(), acc.end(), 0.0);
            std::fill(nrm.begin(), nrm.end(), 0.0);
            for (int f = 1; f <= NF; f++) {
                const float *re = freqBuf.data() + ((size_t)ch * 2 * FR + f) * BINS;
                const float *im = freqBuf.data() + ((size_t)ch * 2 * FR + FR + f) * BINS;

                for (int n = 0; n < NFFT; n++) { Xr[(size_t)n] = 0.0f; Xi[(size_t)n] = 0.0f; }
                for (int k = 0; k < BINS; k++) {
                    Xr[(size_t)k] = re[k];
                    Xi[(size_t)k] = im[k];
                    if (k > 0 && k < NFFT / 2) {
                        Xr[(size_t)(NFFT - k)] =  re[k];
                        Xi[(size_t)(NFFT - k)] = -im[k];
                    }
                }
                fftRadix2(Xr.data(), Xi.data(), NFFT, /*inverse=*/true);

                const int off = (f - 1) * HOP;
                for (int n = 0; n < NFFT; n++) {
                    acc[(size_t)(off + n)] += (double)Xr[(size_t)n] * (double)win[(size_t)n];
                    nrm[(size_t)(off + n)] += (double)win[(size_t)n];
                }
            }

            for (int i = 0; i < TAIL; i++) {
                acc[(size_t)i] += carry[(size_t)ch][(size_t)i];
                nrm[(size_t)i] += carryN[(size_t)ch][(size_t)i];
            }

            for (long i = 0; i < EMIT; i++) {
                double v = (nrm[(size_t)i] > 1e-6) ? acc[(size_t)i] / nrm[(size_t)i] : 0.0;
                v = softClip(v);
                double q = v * 32767.0;
                if (q > 32767.0) q = 32767.0;
                if (q < -32768.0) q = -32768.0;
                inter[(size_t)(i * CH + ch)] = (int16_t)(q >= 0 ? q + 0.5 : q - 0.5);
            }

            for (int i = 0; i < TAIL; i++) {
                carry[(size_t)ch][(size_t)i]  = acc[(size_t)(EMIT + i)];
                carryN[(size_t)ch][(size_t)i] = nrm[(size_t)(EMIT + i)];
            }
        }

        /* 本段 PCM 立即落盘（边转码边播的关键：tail 侧能读到新数据）。 */
        fwrite(inter.data(), 1, inter.size() * 2, w);
        fflush(w);
        totalSamples += EMIT;
        if (progress) progress((long)(totalSamples * CH * 2), user);
    }

    /* 收尾：写出最后一段的残余 */
    for (int i = 0; i < TAIL; i++) {
        for (int ch = 0; ch < CH; ch++) {
            double v = (carryN[(size_t)ch][(size_t)i] > 1e-6)
                           ? carry[(size_t)ch][(size_t)i] / carryN[(size_t)ch][(size_t)i]
                           : 0.0;
            v = softClip(v);
            double q = v * 32767.0;
            if (q > 32767.0) q = 32767.0;
            if (q < -32768.0) q = -32768.0;
            inter[(size_t)(i * CH + ch)] = (int16_t)(q >= 0 ? q + 0.5 : q - 0.5);
        }
    }
    fwrite(inter.data(), 1, (size_t)TAIL * (size_t)CH * 2, w);
    fflush(w);
    totalSamples += TAIL;

    fclose(w);
    if (progress) progress(-1, user);
    LOGI("stream decoded segs=%d -> %ld samples (%ld bytes)", g_hdr.nseg, totalSamples,
         totalSamples * (long)CH * 2);
    return 0;
}

void nacglue_release(void) {
    nacglue_close();
    if (g_destroy && g_interp) g_destroy(g_interp);
    g_interp = NULL;
    g_sess = NULL;
    g_state.clear();
    /* libMNN_dl.so 常驻：进程内复用，避免反复 dlopen 开销 */
}

} /* extern "C" */
