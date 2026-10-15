import 'dart:io';

import 'package:baiji_music/download/download_task.dart';
import 'package:dio/dio.dart';
import 'package:baiji_music/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song(String name, {String mid = 'mid1'}) => Song(
      mid: mid,
      songId: 1,
      name: name,
      singer: '歌手',
      album: '专辑',
      albumMid: '',
      duration: 1000,
      cover: '',
    );

void main() {
  group('DownloadTaskState', () {
    test('终态判定', () {
      expect(DownloadTaskState.done.isTerminal, isTrue);
      expect(DownloadTaskState.failed.isTerminal, isTrue);
      expect(DownloadTaskState.canceled.isTerminal, isTrue);
      expect(DownloadTaskState.queued.isTerminal, isFalse);
      expect(DownloadTaskState.downloading.isTerminal, isFalse);
      expect(DownloadTaskState.finalizing.isTerminal, isFalse);
    });

    test('暂停态：既不是终态也不是活跃', () {
      expect(DownloadTaskState.paused.isTerminal, isFalse);
      expect(DownloadTaskState.paused.isActive, isFalse);
      expect(DownloadTaskState.paused.isPaused, isTrue);
      // 其余状态都不是暂停
      for (final s in DownloadTaskState.values) {
        if (s != DownloadTaskState.paused) expect(s.isPaused, isFalse);
      }
    });

    test('每个状态都有中文标签', () {
      for (final s in DownloadTaskState.values) {
        expect(s.label, isNotEmpty);
      }
    });
  });

  group('DownloadTask.ratio', () {
    test('总长已知 → 返回 0~1', () {
      final t = DownloadTask(
        id: 'a',
        song: _song('x'),
        state: DownloadTaskState.downloading,
        createdAt: 0,
        received: 50,
        total: 100,
      );
      expect(t.ratio, 0.5);
    });

    test('总长未知 → null（不确定进度）', () {
      final t = DownloadTask(
        id: 'a',
        song: _song('x'),
        state: DownloadTaskState.downloading,
        createdAt: 0,
        received: 50,
        total: -1,
      );
      expect(t.ratio, isNull);
      expect(t.isIndeterminate, isTrue);
    });

    test('已完成恒为 1（哪怕字节数没记上）', () {
      final t = DownloadTask(
        id: 'a',
        song: _song('x'),
        state: DownloadTaskState.done,
        createdAt: 0,
      );
      expect(t.ratio, 1.0);
    });

    test('已下载超过总长时钳制在 1', () {
      final t = DownloadTask(
        id: 'a',
        song: _song('x'),
        state: DownloadTaskState.downloading,
        createdAt: 0,
        received: 300,
        total: 100,
      );
      expect(t.ratio, 1.0);
    });
  });

  group('DownloadTask 序列化', () {
    test('只恢复已完成任务，进行中的不恢复', () {
      final t = DownloadTask(
        id: 'a',
        song: _song('晴天'),
        state: DownloadTaskState.done,
        createdAt: 100,
        received: 100,
        total: 100,
        filePath: '/m/晴天.mp3',
        qualityLabel: 'SQ 无损',
      );
      final back = DownloadTask.fromJson(t.toJson());
      expect(back, isNotNull);
      expect(back!.state, DownloadTaskState.done);
      expect(back.song.name, '晴天');
      expect(back.filePath, '/m/晴天.mp3');
      expect(back.qualityLabel, 'SQ 无损');
    });

    test('暂停态原样恢复（partPath 也在）', () {
      final dir = Directory.systemTemp.createTempSync('dlp');
      final part = File('${dir.path}/song.mp3.part')
        ..writeAsBytesSync([1, 2, 3]);
      addTearDown(() => dir.deleteSync(recursive: true));

      final t = DownloadTask(
        id: 'p',
        song: _song('暂停曲'),
        state: DownloadTaskState.paused,
        createdAt: 100,
        received: 3,
        total: 10,
        partPath: part.path,
      );
      final back = DownloadTask.fromJson(t.toJson());
      expect(back, isNotNull);
      expect(back!.state, DownloadTaskState.paused);
      expect(back.partPath, part.path);
      expect(back.canResume, isTrue);
    });

    test('暂停态但残片文件没了 → 降级为失败', () {
      final t = DownloadTask(
        id: 'p',
        song: _song('暂停曲'),
        state: DownloadTaskState.paused,
        createdAt: 100,
        received: 3,
        total: 10,
        partPath: '/nonexistent/gone.part',
      );
      final back = DownloadTask.fromJson(t.toJson());
      expect(back, isNotNull);
      expect(back!.state, DownloadTaskState.failed);
      expect(back.canResume, isFalse);
    });

    test('活跃态持久化数据 → 按失败恢复（进程被杀不可信）', () {
      final t = DownloadTask(
        id: 'd',
        song: _song('被杀曲'),
        state: DownloadTaskState.downloading,
        createdAt: 100,
        received: 5,
        total: 10,
        partPath: '/x.part',
      );
      final back = DownloadTask.fromJson(t.toJson());
      expect(back!.state, DownloadTaskState.failed);
    });

    test('canResume：非暂停态一律 false', () {
      for (final s in DownloadTaskState.values) {
        if (s == DownloadTaskState.paused) continue;
        final t = DownloadTask(
          id: 'x',
          song: _song('x'),
          state: s,
          createdAt: 0,
          partPath: '/whatever.part',
        );
        expect(t.canResume, isFalse, reason: 'state=$s');
      }
    });

    test('缺文件路径 → null', () {
      final m = {'id': 'a', 'song': _song('x').toJson(), 'filePath': ''};
      expect(DownloadTask.fromJson(m), isNull);
    });

    test('song 字段类型不对→ null', () {
      expect(DownloadTask.fromJson({'id': 'a', 'song': 123}), isNull);
    });
  });

  group('downloadedSongOf', () {
    test('转成可直接播放的本地 Song', () {
      final dir = Directory.systemTemp.createTempSync('dl');
      final f = File('${dir.path}/周杰伦 - 晴天.mp3')
        ..writeAsBytesSync([1, 2, 3]);
      addTearDown(() => dir.deleteSync(recursive: true));

      final t = DownloadTask(
        id: 'a',
        song: _song('晴天'),
        state: DownloadTaskState.done,
        createdAt: 0,
        filePath: f.path,
      );

      final s = downloadedSongOf(t);
      // isLocal 依赖 localPath 非空，播放器才肯播
      expect(s.isLocal, isTrue);
      expect(s.localPath, f.path);
      expect(s.source, Source.local);
      expect(s.name, '晴天');
      expect(s.localSize, 3);
      expect(s.format, 'mp3');
    });

    test('扩展名从文件路径推断', () {
      final s = downloadedSongOf(DownloadTask(
        id: 'a',
        song: _song('x'),
        state: DownloadTaskState.done,
        createdAt: 0,
        filePath: '/m/song.FLAC',
      ));
      expect(s.format, 'flac');
    });
  });

  group('DownloadTaskRegistry', () {
    test('enqueue 后任务出现在列表里且状态为等待', () {
      final reg = DownloadTaskRegistry.instance;
      final before = reg.tasks.length;
      final t = reg.enqueue(_song('排队曲', mid: 'q1'));
      expect(reg.tasks.length, before + 1);
      expect(reg.tasks.first.id, t.id);
      expect(t.state, DownloadTaskState.queued);
      expect(reg.activeCount, greaterThan(0));
      reg.remove(t.id);
    });

    test('update 能改状态并广播', () async {
      final reg = DownloadTaskRegistry.instance;
      final t = reg.enqueue(_song('更新曲', mid: 'u1'));
      final got = reg.changes.first;
      reg.update(t.id, (x) => x.copyWith(state: DownloadTaskState.downloading, received: 10, total: 100));
      final list = await got;
      final updated = list.firstWhere((e) => e.id == t.id);
      expect(updated.state, DownloadTaskState.downloading);
      expect(updated.ratio, 0.1);
      reg.remove(t.id);
    });

    test('update 不存在的 id 不抛异常', () {
      final reg = DownloadTaskRegistry.instance;
      expect(() => reg.update('nope', (x) => x), returnsNormally);
    });

    test('进行中的任务不允许被移除', () {
      final reg = DownloadTaskRegistry.instance;
      final t = reg.enqueue(_song('不可移除', mid: 'r1'));
      expect(reg.remove(t.id), isFalse);
      reg.update(t.id, (x) => x.copyWith(state: DownloadTaskState.done, filePath: '/x.mp3'));
      expect(reg.remove(t.id), isTrue);
    });

    test('clearFinished 只清终态任务', () {
      final reg = DownloadTaskRegistry.instance;
      final active = reg.enqueue(_song('还在跑', mid: 'a1'));
      final done = reg.enqueue(_song('已结束', mid: 'd1'));
      reg.update(done.id, (x) => x.copyWith(state: DownloadTaskState.done, filePath: '/y.mp3'));
      final n = reg.clearFinished();
      expect(n, greaterThanOrEqualTo(1));
      expect(reg.tasks.any((e) => e.id == active.id), isTrue);
      expect(reg.tasks.any((e) => e.id == done.id), isFalse);
      reg.remove(active.id);
    });

    test('进行中的任务排在已完成之前', () {
      final reg = DownloadTaskRegistry.instance;
      final done = reg.enqueue(_song('已完成', mid: 'x1'));
      reg.update(done.id, (x) => x.copyWith(state: DownloadTaskState.done, filePath: '/z.mp3'));
      final active = reg.enqueue(_song('进行中', mid: 'x2'));
      final ids = reg.tasks.map((e) => e.id).toList();
      expect(ids.indexOf(active.id), lessThan(ids.indexOf(done.id)));
      reg.remove(done.id);
      reg.update(active.id, (x) => x.copyWith(state: DownloadTaskState.failed));
      reg.remove(active.id);
    });

    test('暂停的任务可被移除，并允许点继续', () {
      final reg = DownloadTaskRegistry.instance;
      final t = reg.enqueue(_song('暂停中', mid: 'pz'));
      reg.update(t.id, (x) => x.copyWith(state: DownloadTaskState.paused, partPath: '/tmp/x.part'));
      // 暂停态不在活跃集合里
      expect(reg.activeTasks.any((e) => e.id == t.id), isFalse);
      // 可以移除（不等同于进行中的强制先取消）
      expect(reg.remove(t.id), isTrue);
    });

    test('requestPause / requestCancel 下发到绑定的令牌', () {
      final reg = DownloadTaskRegistry.instance;
      final t = reg.enqueue(_song('令牌曲', mid: 'tk'));
      final token = CancelToken();
      reg.bindToken(t.id, token);
      reg.requestPause(t.id);
      expect(token.isCancelled, isTrue);
      // dio 把 reason 包进 DioException.error
      expect(token.cancelError?.error, kDownloadPauseSignal);
      reg.unbindToken(t.id);

      final t2 = reg.enqueue(_song('令牌曲2', mid: 'tk2'));
      final token2 = CancelToken();
      reg.bindToken(t2.id, token2);
      reg.requestCancel(t2.id);
      expect(token2.isCancelled, isTrue);
      expect(token2.cancelError?.error, kDownloadCancelSignal);
      reg.unbindToken(t2.id);
      reg.update(t2.id, (x) => x.copyWith(state: DownloadTaskState.canceled));
      reg.remove(t2.id);
    });

    test('未绑定令牌时 requestPause 不抛异常', () {
      final reg = DownloadTaskRegistry.instance;
      final t = reg.enqueue(_song('无令牌', mid: 'nt'));
      expect(() => reg.requestPause(t.id), returnsNormally);
      expect(() => reg.requestCancel(t.id), returnsNormally);
      reg.update(t.id, (x) => x.copyWith(state: DownloadTaskState.canceled));
      reg.remove(t.id);
    });
  });
}