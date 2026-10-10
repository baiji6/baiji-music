/// 解密产物的音频格式校验。
///
/// 移植自 um-react `src/decrypt-worker/util/audioType.ts`：
///
/// ```ts
/// export function detectAudioExtension(buffer: Uint8Array): string {
///   let neededLength = 0x100;
///   let extension = 'bin';
///   while (neededLength !== 0) {
///     const detectResult = detectAudioType(buffer.subarray(0, neededLength));
///     extension = detectResult.audioType;
///     neededLength = detectResult.needMore;
///   }
///   return extension;
/// }
///
/// export function isDataLooksLikeAudio(buffer: Uint8Array): boolean {
///   if (buffer.byteLength < 0x20) return false;
///   const detectResult = detectAudioType(buffer.subarray(0, 0x20));
///   // needMore != 0 意味着看到了合法头部（比如 ID3）
///   const ok = detectResult.needMore !== 0 || detectResult.audioType !== 'bin';
///   return ok;
/// }
/// ```
///
/// **为什么必须有这一步**：密钥填错、版本判断错、偏移猜错，解密都会"成功"，
/// 只是产出一堆随机字节。没有校验的话，用户拿到的是一个能播放但全是噪声的
/// 文件，而且完全不知道是哪里错了。上游正是靠这个校验在解密器之间试错——
/// 谁产出合法音频就用谁。
library;

/// 探测到的音频格式。`bin` 表示不认识。
class AudioFormat {
  const AudioFormat(this.extension, {this.needMore = 0});

  final String extension;

  /// 上游 `detectAudioType` 的 `needMore`：**非 0 表示头部已确认合法**
  /// （典型是 ID3），只是还想再读一些字节确认；0 表示已判定完毕。
  ///
  /// 未识别的格式恒为 0 —— 否则会被 [isDataLooksLikeAudio] 误判为音频。
  final int needMore;

  bool get isKnown => extension != 'bin';

  /// MIME type，用于导出文件。
  String get mimeType => switch (extension) {
        'mp3' => 'audio/mpeg',
        'flac' => 'audio/flac',
        'm4a' => 'audio/mp4',
        'ogg' => 'audio/ogg',
        'wma' => 'audio/x-ms-wma',
        'wav' => 'audio/x-wav',
        'dff' => 'audio/x-dff',
        _ => 'application/octet-stream',
      };
}

/// 探测头部字节里的音频格式。
///
/// 行为与上游`detectAudioExtension` 一致：先看 0x100 字节，
/// 认不出来就按需追加更多字节再试。
AudioFormat detectAudioFormat(List<int> data) {
  if (data.isEmpty) return const AudioFormat('bin');
  final want = data.length < 0x100 ? data.length : 0x100;
  return _detect(data, want);
}

AudioFormat _detect(List<int> data, int window) {
  // mp3：ID3 标签。
  //
  // 上游对 ID3 返回 `needMore != 0`（表示"头部合法但还想再确认"），
  // 这是 [isDataLooksLikeAudio] 判定合法的主要依据，必须原样保留。
  if (window >= 3 &&
      data[0] == 0x49 &&
      data[1] == 0x44 &&
      data[2] == 0x33) {
    return const AudioFormat('mp3', needMore: 0x20);
  }

  // flac：fLaC
  if (window >= 4 &&
      data[0] == 0x66 &&
      data[1] == 0x4C &&
      data[2] == 0x61 &&
      data[3] == 0x43) {
    return const AudioFormat('flac');
  }

  // mp4 / m4a：....ftyp<major>
  if (window >= 12) {
    final brand = String.fromCharCodes(data.sublist(8, 12));
    if (data[4] == 0x66 &&
        data[5] == 0x74 &&
        data[6] == 0x79 &&
        data[7] == 0x70 &&
        const {'isom', 'mp42', 'M4A ', 'M4B ', 'dash'}.contains(brand)) {
      return const AudioFormat('m4a');
    }
  }

  // ogg：OggS
  if (window >= 4 &&
      data[0] == 0x4F &&
      data[1] == 0x67 &&
      data[2] == 0x67 &&
      data[3] == 0x53) {
    return const AudioFormat('ogg');
  }

  // wav：RIFF....WAVE
  if (window >= 12 &&
      data[0] == 0x52 &&
      data[1] == 0x49 &&
      data[2] == 0x46 &&
      data[3] == 0x46 &&
      data[8] == 0x57 &&
      data[9] == 0x41 &&
      data[10] == 0x56 &&
      data[11] == 0x45) {
    return const AudioFormat('wav');
  }

  // wma：ASF 头 GUID 30 26 B2 75 8E 66 CF 11 A6 D9 00 AA 00 62 CE 6C
  if (window >= 16 &&
      data[0] == 0x30 &&
      data[1] == 0x26 &&
      data[2] == 0xB2 &&
      data[3] == 0x75 &&
      data[4] == 0x8E &&
      data[5] == 0x66 &&
      data[6] == 0xCF &&
      data[7] == 0x11) {
    return const AudioFormat('wma');
  }

  // DSD：'FRM8' 容器里的 'DSD '
  if (window >= 16) {
    final dsd = String.fromCharCodes(data.sublist(0, 4));
    if (dsd == 'FRM8' &&
        String.fromCharCodes(data.sublist(12, 16)) == 'DSD ') {
      return const AudioFormat('dff');
    }
  }

  // mp3 无 ID3：帧同步字 0xFFEx/Fx。
  //
  // 这里必须校验 layer 与bitrate 版本位，否则任何以 0xFF 0xEx 开头的
  // 随机字节都会被误判成 mp3——密钥解密失败产出的正是随机字节，
  // 太宽松会让校验形同虚设。
  if (window >= 4) {
    final b0 = data[0];
    final b1 = data[1];
    final b2 = data[2];
    if (b0 == 0xFF && (b1 & 0xE0) == 0xE0) {
      // 00=保留01=LayerIII 10=LayerII 11=LayerI
      final layer = (b1 >> 1) & 0x03;
      // 00=MPEG2.5 01=保留 10=MPEG2 11=MPEG1
      final version = (b1 >> 3) & 0x03;
      final bitrate = (b2 >> 4) & 0x0F; // 1111=非法
      final sampleRate = (b2 >> 2) & 0x03; // 11=保留
      if (layer != 0 &&
          version != 0x01 && // 01 是保留值
          bitrate != 0x0F &&
          bitrate != 0x00 && // 0000=自由格式，非常见
          sampleRate != 0x03) {
        return const AudioFormat('mp3');
      }
    }
  }

  // 认不出来。
  //
  // 注意 needMore 在这里**恒为 0**：它只用于表达"头部已确认合法但还想再看看"
  // （如 ID3）。若未识别时也返回非 0，[isDataLooksLikeAudio] 的
  // `needMore != 0` 判据就会把任何随机字节当成合法头部，校验形同虚设。
  return const AudioFormat('bin');
}

/// 头部数据看起来像音频吗（对应上游 `isDataLooksLikeAudio`）。
///
/// 至少要 0x20 字节。上游的判据是`needMore != 0 || audioType !== 'bin'`：
/// 前者覆盖"已确认的合法头部但还想再看看"（如 ID3），后者覆盖
/// flac / m4a / ogg这类自带 magic 的格式。
bool isDataLooksLikeAudio(List<int> data) {
  if (data.length < 0x20) return false;
  final r = _detect(data.sublist(0, 0x20), 0x20);
  return r.needMore != 0 || r.isKnown;
}