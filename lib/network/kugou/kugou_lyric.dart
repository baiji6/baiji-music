// 酷狗歌词 —— KRC 逐字解密 + KRC → [Lyrics] 转换。
//
// 抄 Lyrico kugou 插件的歌词逻辑（lyrics.kugou.com 两步走 + KRC 解密）：
//   1) v1/search  拿 candidates[0].id + accesskey
//   2) /download  拿 base64 的 KRC 密文（contenttype≠2）
//   3) 解密：去 4 字节头 → base64 解码 → 与 16 字节密钥 XOR → zlib 解压
//   4) 解析 KRC（逐字 + 译文 type=1 + 罗马音 type=0）
//
// 与 [kugou_api.dart] 解耦：本文件只接收 hash，不反向依赖它，避免循环导入。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../lyrics/lyric_model.dart';
import 'kugou_cipher.dart';

/// KRC 解密密钥（Lyrico 插件 `KRC_KEY`）。
const List<int> _krcKey = [
  64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105
];

const String _lyricSearch = 'https://lyrics.kugou.com/v1/search';
const String _lyricDownload = 'https://lyrics.kugou.com/download';
const String _lyricUa =
    'Android14-1070-11070-201-0-SearchSong-wifi';

final Dio _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));

Future<Map<String, dynamic>> _getJson(String url,
    {Map<String, String>? headers}) async {
  final resp = await _dio.get<String>(url,
      options: Options(headers: headers ?? const {'User-Agent': _lyricUa}));
  final body = resp.data ?? '';
  final decoded = jsonDecode(body);
  if (decoded is! Map) return const {};
  return Map<String, dynamic>.from(decoded);
}

/// 按 hash 取歌词（KRC 解密后转 [Lyrics]）；失败返回 [Lyrics.empty]。
Future<Lyrics> lyricsForSong(String hash, String name, String singer) async {
  if (hash.isEmpty) return Lyrics.empty;
  try {
    // 1) 搜候选
    final searchParams = <String, String>{
      'album_audio_id': '0',
      'duration': '0',
      'hash': hash,
      'keyword': '$singer - $name',
      'lrctxt': '1',
      'man': 'no',
      'appid': '3116',
      'clientver': '11070',
    };
    searchParams['signature'] = kugouSign(searchParams, kugouLyricSalt);
    final searchUrl = '$_lyricSearch?${kugouBuildQuery(searchParams)}';
    final searchResp = await _getJson(searchUrl);
    final cands = searchResp['candidates'];
    if (cands is! List || cands.isEmpty) return Lyrics.empty;
    final cand = Map<String, dynamic>.from(cands.first as Map);
    final id = '${cand['id']}';
    final accesskey = '${cand['accesskey']}';
    if (id.isEmpty || accesskey.isEmpty) return Lyrics.empty;

    // 2) 下载 KRC
    final dlParams = <String, String>{
      'accesskey': accesskey,
      'charset': 'utf8',
      'client': 'mobi',
      'fmt': 'krc',
      'id': id,
      'ver': '1',
      'appid': '3116',
      'clientver': '11070',
    };
    dlParams['signature'] = kugouSign(dlParams, kugouLyricSalt);
    final dlUrl = '$_lyricDownload?${kugouBuildQuery(dlParams)}';
    final dlResp = await _getJson(dlUrl);
    final content = dlResp['content'];
    if (content is! String || content.isEmpty) return Lyrics.empty;
    final contenttype = dlResp['contenttype'] ?? 0;

    // 3) 解密
    final krcText = (contenttype == 2)
        ? utf8.decode(base64Decode(content))
        : _decryptKrc(content);
    if (krcText.isEmpty) return Lyrics.empty;

    return _parseKrc(krcText, name, singer);
  } catch (e) {
    return Lyrics.empty;
  }
}

/// KRC 解密：去 4 字节头 → base64 解码 → XOR 密钥 → zlib 解压。
String _decryptKrc(String base64Content) {
  try {
    final raw = base64Decode(base64Content);
    if (raw.length <= 4) return '';
    final body = raw.sublist(4);
    final xored = Uint8List.fromList(
        List<int>.generate(body.length, (i) => body[i] ^ _krcKey[i % _krcKey.length]));
    final inflated = zlib.decode(xored);
    return utf8.decode(inflated);
  } catch (_) {
    return '';
  }
}

class _KrcLine {
  _KrcLine(this.startMs, this.endMs, this.words, this.text);
  final int startMs;
  final int endMs;
  final List<LyricWord> words;
  final String text;
}

/// 解析 KRC 文本为 [Lyrics]（逐字 + 译文 + 罗马音）。
Lyrics _parseKrc(String krc, String name, String singer) {
  final tags = <String, String>{};
  final original = <_KrcLine>[];
  List<dynamic> languageItems = const [];

  for (final rawLine in krc.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || !line.startsWith('[')) continue;

    final tag = RegExp(r'^\[(\w+):([^\]]*)\]').firstMatch(line);
    if (tag != null) {
      tags[tag.group(1)!] = tag.group(2) ?? '';
      if (tag.group(1) == 'language') languageItems = _parseLanguageTag(tags['language']!);
      continue;
    }

    final lineMatch = RegExp(r'^\[(\d+),(\d+)\](.*)$').firstMatch(line);
    if (lineMatch == null) continue;

    final lineStart = int.parse(lineMatch.group(1)!);
    final lineDur = int.parse(lineMatch.group(2)!);
    final lineEnd = lineStart + lineDur;
    final content = lineMatch.group(3) ?? '';

    final wordRe = RegExp(r'<(\d+),(\d+),\d+>([^<]*)');
    final matches = wordRe.allMatches(content).toList();
    final words = <LyricWord>[];
    for (var i = 0; i < matches.length; i++) {
      final wm = matches[i];
      final off = int.parse(wm.group(1)!);
      final dur = int.parse(wm.group(2)!);
      final tw = wm.group(3) ?? '';
      final wStart = lineStart + off;
      final wEnd = dur > 0
          ? wStart + dur
          : (i < matches.length - 1
              ? lineStart + int.parse(matches[i + 1].group(1)!)
              : lineEnd);
      words.add(LyricWord(startMs: wStart, endMs: wEnd, text: tw));
    }

    String plain;
    if (words.isNotEmpty) {
      plain = words.map((w) => w.text).join();
    } else {
      // 无逐字标记：整行作普通文本
      plain = content;
    }
    original.add(_KrcLine(lineStart, lineEnd, words, plain));
  }

  // 译文（type=1）/ 罗马音（type=0）按行对齐
  final Map<int, String> translations = {};
  final Map<int, String> romanizations = {};
  for (final item in languageItems) {
    if (item is! Map) continue;
    final content = item['lyricContent'];
    final type = item['type'];
    if (content is! List) continue;
    if (type == 1) {
      for (var i = 0; i < content.length && i < original.length; i++) {
        final t = content[i];
        final s = t is List ? (t.isNotEmpty ? '${t[0]}' : '') : '';
        if (s.isNotEmpty) translations[i] = s;
      }
    } else if (type == 0) {
      // 罗马音跳过空行（对齐 master 行为）
      var skipped = 0;
      for (var i = 0; i < original.length; i++) {
        if (original[i].words.isEmpty && original[i].text.isEmpty) {
          skipped++;
          continue;
        }
        final idx = i - skipped;
        if (idx >= 0 && idx < content.length) {
          final entry = content[idx];
          final s = entry is List
              ? entry.map((x) => '$x'.trim()).where((e) => e.isNotEmpty).join(' ')
              : '';
          if (s.isNotEmpty) romanizations[i] = s;
        }
      }
    }
  }

  final lines = <LyricLine>[];
  for (var i = 0; i < original.length; i++) {
    final o = original[i];
    lines.add(LyricLine(
      startMs: o.startMs,
      endMs: o.endMs,
      text: o.text,
      words: o.words,
      translation: translations[i],
      romanization: romanizations[i],
    ));
  }
  lines.sort((a, b) => a.startMs.compareTo(b.startMs));

  final hasWord = lines.any((l) => l.isWordLevel);
  final hasTrans = lines.any((l) => l.translation != null && l.translation!.isNotEmpty);
  final hasRoma = lines.any((l) => l.romanization != null && l.romanization!.isNotEmpty);
  return Lyrics(
    lines: lines,
    hasWordTiming: hasWord,
    hasTranslation: hasTrans,
    hasRomanization: hasRoma,
  );
}

/// 解析 KRC `language` 标签（base64 JSON）。
List<dynamic> _parseLanguageTag(String tag) {
  if (tag.isEmpty) return const [];
  try {
    final decoded = jsonDecode(utf8.decode(base64Decode(tag)));
    if (decoded is Map && decoded['content'] is List) return decoded['content'] as List;
  } catch (_) {}
  return const [];
}

/// 取歌词入口（供 [KugouApi.lyric] 调用，先做轻量搜索拿 hash）。
Future<Lyrics> getLyrics(String mixSongId, String name, String singer) async {
  // 复用 KugouApi 的解析较复杂，这里直接按歌名+歌手搜一次拿 hash。
  // 注意：避免与 kugou_api 循环依赖，搜索逻辑内联。
  try {
    final mid = kugouDeviceMid();
    final params = <String, String>{
      'keyword': '$name $singer'.trim(),
      'page': '1',
      'pagesize': '1',
      'platform': 'AndroidFilter',
      'iscorrection': '1',
      'area_code': '1',
      'dopicfull': '1',
      'albumhide': '0',
      'nocollect': '0',
      'dfid': '-',
      'mid': mid,
      'uuid': '-',
      'appid': '1005',
      'clientver': '20489',
      'clienttime': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    };
    params['signature'] = kugouSign(params, kugouGatewaySalt);
    final url =
        'https://gateway.kugou.com/v2/search/song?${kugouBuildQuery(params)}';
    final headers = {
      'User-Agent': _lyricUa,
      'x-router': 'complexsearch.kugou.com',
      'kg-rc': '1',
      'kg-thash': '5d816a0',
      'kg-rec': '1',
      'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
      'kg-tid': '255',
    };
    final data = await _getJson(url, headers: headers);
    final list = (data['data'] is Map ? (data['data'] as Map)['lists'] : null);
    if (list is! List || list.isEmpty) return Lyrics.empty;
    final m = Map<String, dynamic>.from(list.first as Map);
    final hash = '${m['FileHash'] ?? ''}';
    if (hash.isEmpty) return Lyrics.empty;
    return await lyricsForSong(hash, name, singer);
  } catch (_) {
    return Lyrics.empty;
  }
}
