// 下载歌词选项（#77）：默认逐字、无逐字回退逐行的契约测试。
import 'package:baiji_music/core/kv_store.dart';
import 'package:baiji_music/download/download_extras.dart';
import 'package:baiji_music/lyrics/lyric_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 带逐字时间轴的歌词。
Lyrics _wordLyrics() => Lyrics(
      hasWordTiming: true,
      lines: <LyricLine>[
        LyricLine(
          startMs: 1000,
          endMs: 2000,
          text: '有逐字',
          words: const <LyricWord>[
            LyricWord(startMs: 1000, endMs: 1500, text: '有'),
            LyricWord(startMs: 1500, endMs: 2000, text: '逐'),
            LyricWord(startMs: 2000, endMs: 2000, text: '字'),
          ],
        ),
      ],
    );

/// 只有整行时间轴的歌词（普通 LRC）。
Lyrics _lineLyrics() => const Lyrics(
      hasWordTiming: false,
      lines: <LyricLine>[
        LyricLine(startMs: 1000, endMs: 2000, text: '只有整行'),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await KvStore.ensureInit();
    await KvStore.instance.clear();
  });

  group('resolveLyricMode（逐字 → 无逐字回退逐行）', () {
    test('请求逐字且有逐字数据 → 仍是逐字', () {
      expect(DownloadExtras.resolveLyricMode(LyricDownloadMode.word, _wordLyrics()),
          LyricDownloadMode.word);
    });

    test('请求逐字但没有逐字数据 → 回退逐行', () {
      expect(DownloadExtras.resolveLyricMode(LyricDownloadMode.word, _lineLyrics()),
          LyricDownloadMode.line);
    });

    test('逐行 / 不下载不受影响', () {
      expect(DownloadExtras.resolveLyricMode(LyricDownloadMode.line, _lineLyrics()),
          LyricDownloadMode.line);
      expect(DownloadExtras.resolveLyricMode(LyricDownloadMode.off, _wordLyrics()),
          LyricDownloadMode.off);
    });
  });

  group('默认歌词模式', () {
    test('未设置过 → 逐字（默认逐字，无逐字自动回退逐行）', () {
      expect(DownloadExtras.lyricMode, LyricDownloadMode.word);
    });

    test('设置过的值被持久化读取', () async {
      await DownloadExtras.setLyricMode(LyricDownloadMode.line);
      expect(DownloadExtras.lyricMode, LyricDownloadMode.line);
      await DownloadExtras.setLyricMode(LyricDownloadMode.off);
      expect(DownloadExtras.lyricMode, LyricDownloadMode.off);
    });

    test('逐字模式的描述说明了回退语义', () {
      expect(LyricDownloadMode.word.description, contains('逐行'));
      expect(LyricDownloadMode.word.label, '逐字歌词');
      expect(LyricDownloadMode.line.label, '逐行歌词');
      expect(LyricDownloadMode.off.label, '不下载');
    });
  });
}
