import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/services/evantube/drive_sync.dart';
import 'package:spotube/services/evantube/journal.dart';
import 'package:spotube/services/playlist_import/playlist_import.dart';
import 'package:uuid/uuid.dart';

class EvanTubeLibraryPage extends ConsumerStatefulWidget {
  const EvanTubeLibraryPage({super.key});
  @override
  ConsumerState<EvanTubeLibraryPage> createState() =>
      _EvanTubeLibraryPageState();
}

class _EvanTubeLibraryPageState extends ConsumerState<EvanTubeLibraryPage> {
  final sync = EvanDriveSync.instance;
  final messenger = GlobalKey<ScaffoldMessengerState>();
  String? selectedId;

  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted)
        messenger.currentState?.showSnackBar(SnackBar(
            content:
                Text(e is FormatException ? e.message : '操作失敗；本機歌單未變更。請重試。')));
    }
  }

  Future<String?> input(String title, {String initial = ''}) async {
    var text = initial;
    final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(title),
                content: TextFormField(
                    initialValue: initial,
                    onChanged: (value) => text = value,
                    autofocus: true,
                    maxLength: 1000),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () {
                        if (text.trim().isNotEmpty)
                          Navigator.pop(context, text.trim());
                      },
                      child: const Text('儲存'))
                ]));
    return result;
  }

  Future<bool> confirm(String title, String body) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) =>
              AlertDialog(title: Text(title), content: Text(body), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('確認'))
              ])) ??
      false;

  Future<void> connect() async {
    await sync.connect();
    if (!mounted || sync.account == null) return;
    if (await confirm('啟用 Google Drive 同步',
        '將目前所有 EvanTube 本機歌單合併至 ${sync.account!.email}，並下載此帳號的 EvanTube 歌單。來源外掛歌單不包含在內。'))
      await sync.activate();
  }

  Future<void> importPlaylists() async {
    final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip', 'json', 'csv', 'txt', 'm3u', 'm3u8']);
    if (picked == null) return;
    final file = picked.files.single;
    if (file.size > 32 * 1024 * 1024)
      throw const FormatException('檔案不可超過 32 MB。');
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    final doc = parsePlaylistImport(bytes, file.name);
    final edits = <Map<String, dynamic>>[];
    var skipped = 0;
    for (final playlist in doc.playlists) {
      final id = const Uuid().v4();
      edits.add({'kind': 'create', 'playlistId': id, 'title': playlist.name});
      for (final track in playlist.tracks) {
        if (track.youtubeId == null) {
          skipped++;
          continue;
        }
        edits.add({
          'kind': 'putSong',
          'playlistId': id,
          'song': {
            'youtubeId': track.youtubeId,
            'title': track.title,
            'artist': track.artist,
            'duration': track.durationSeconds,
            'thumbnailURL': null
          }
        });
      }
    }
    await sync.mutate(edits);
    if (mounted)
      messenger.currentState?.showSnackBar(SnackBar(
          content: Text(
              '已匯入 ${doc.playlists.length} 份歌單；略過 $skipped 首無 YouTube ID 的歌曲。${doc.warnings.isEmpty ? '' : '\n${doc.warnings.take(3).join('\n')}'}')));
  }

  Future<void> play(EvanPlaylist playlist, int index) async {
    if (playlist.songs.isEmpty) return;
    final tracks = playlist.songs.map((s) {
      final url = 'https://www.youtube.com/watch?v=${s['youtubeId']}';
      final artists = [
        SpotubeSimpleArtistObject(
            id: s['artist'], name: s['artist'], externalUri: url)
      ];
      return SpotubeFullTrackObject(
          id: 'evantube-youtube:${s['youtubeId']}',
          name: s['title'],
          externalUri: url,
          artists: artists,
          durationMs: (s['duration'] as int) * 1000,
          isrc: '',
          explicit: false,
          album: SpotubeSimpleAlbumObject(
              id: 'evantube:${playlist.id}',
              name: playlist.title,
              externalUri: url,
              artists: artists,
              albumType: SpotubeAlbumType.album,
              images: [
                if (s['thumbnailURL'] != null)
                  SpotubeImageObject(
                      url: s['thumbnailURL'], width: 320, height: 180)
              ]));
    }).toList();
    await ref
        .read(audioPlayerProvider.notifier)
        .load(tracks, initialIndex: index, autoPlay: true);
  }

  Future<void> addSong(EvanPlaylist playlist) async {
    final raw = await input('YouTube 連結或影片 ID');
    if (raw == null) return;
    final id = youtubeIdFromImport(raw);
    if (id == null) throw const FormatException('請輸入有效的 YouTube 連結或 11 字元 ID。');
    if (!mounted) return;
    final title = await input('歌曲名稱', initial: id);
    if (title == null) return;
    await sync.mutate([
      {
        'kind': 'putSong',
        'playlistId': playlist.id,
        'song': {
          'youtubeId': id,
          'title': title,
          'artist': '',
          'duration': 0,
          'thumbnailURL': null
        }
      }
    ]);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: sync,
      builder: (context, _) {
        final playlists = sync.ready ? sync.store!.playlists : <EvanPlaylist>[];
        final selected = playlists.where((p) => p.id == selectedId).firstOrNull;
        return ScaffoldMessenger(
            key: messenger,
            child: Scaffold(
              appBar: AppBar(
                  title: Text(selected?.title ?? 'EvanTube 本機歌單'),
                  leading: selected == null
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.arrow_back),
                          tooltip: '返回歌單',
                          onPressed: () => setState(() => selectedId = null))),
              body: Column(children: [
                if (sync.syncing) const LinearProgressIndicator(),
                Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Google Drive 僅同步 EvanTube／MB3 歌單'),
                          Text(sync.account?.email ?? '尚未連接 Google'),
                          if (sync.store?.lastSync != null)
                            Text('上次成功同步：${sync.store!.lastSync!.toLocal()}'),
                          if (sync.error != null)
                            Text(sync.error!,
                                style: const TextStyle(color: Colors.red)),
                          Wrap(spacing: 8, children: [
                            if (!sync.ready)
                              TextButton(
                                  onPressed: sync.initialize,
                                  child: const Text('重新載入本機歌單')),
                            TextButton(
                                onPressed: !sync.ready || sync.syncing
                                    ? null
                                    : () => run(connect),
                                child: Text(sync.account == null
                                    ? '連接 Google Drive'
                                    : '切換帳號')),
                            if (sync.account != null && !sync.active)
                              TextButton(
                                  onPressed: sync.syncing
                                      ? null
                                      : () => run(() async {
                                            if (await confirm('啟用同步',
                                                '將目前本機歌單合併至 ${sync.account!.email}？'))
                                              await sync.activate();
                                          }),
                                  child: const Text('啟用此帳號')),
                            if (sync.active)
                              TextButton(
                                  onPressed: sync.syncing ? null : sync.sync,
                                  child: const Text('立即同步／重試')),
                            if (sync.account != null)
                              TextButton(
                                  onPressed: () => run(sync.disconnect),
                                  child: const Text('中斷連接')),
                          ]),
                          if (sync.ready)
                            Wrap(
                                spacing: 8,
                                children: selected == null
                                    ? [
                                        FilledButton(
                                            onPressed: () => run(() async {
                                                  final title =
                                                      await input('新增歌單');
                                                  if (title != null)
                                                    await sync.mutate([
                                                      {
                                                        'kind': 'create',
                                                        'playlistId':
                                                            const Uuid().v4(),
                                                        'title': title
                                                      }
                                                    ]);
                                                }),
                                            child: const Text('新增歌單')),
                                        OutlinedButton(
                                            onPressed: () =>
                                                run(importPlaylists),
                                            child: const Text('匯入 MB3／ZIP')),
                                      ]
                                    : [
                                        FilledButton(
                                            onPressed: () =>
                                                run(() => play(selected, 0)),
                                            child: const Text('播放歌單')),
                                        OutlinedButton(
                                            onPressed: () =>
                                                run(() => addSong(selected)),
                                            child: const Text('新增歌曲')),
                                        TextButton(
                                            onPressed: () => run(() async {
                                                  final title = await input(
                                                      '歌單名稱',
                                                      initial: selected.title);
                                                  if (title != null)
                                                    await sync.mutate([
                                                      {
                                                        'kind': 'rename',
                                                        'playlistId':
                                                            selected.id,
                                                        'title': title
                                                      }
                                                    ]);
                                                }),
                                            child: const Text('重新命名')),
                                        TextButton(
                                            onPressed: () => run(() async {
                                                  if (await confirm('刪除歌單',
                                                      '刪除「${selected.title}」？此變更會同步至其他裝置。'))
                                                    await sync.mutate([
                                                      {
                                                        'kind': 'delete',
                                                        'playlistId':
                                                            selected.id
                                                      }
                                                    ]);
                                                }),
                                            child: const Text('刪除歌單')),
                                      ]),
                        ])),
                Expanded(
                    child: !sync.ready
                        ? const Center(child: Text('正在載入本機歌單…'))
                        : ReorderableListView.builder(
                            itemCount:
                                selected?.songs.length ?? playlists.length,
                            onReorder: (oldIndex, newIndex) => run(() async {
                              final order = selected == null
                                  ? playlists.map((p) => p.id).toList()
                                  : selected.songs
                                      .map((s) => s['youtubeId'] as String)
                                      .toList();
                              if (newIndex > oldIndex) newIndex--;
                              order.insert(newIndex, order.removeAt(oldIndex));
                              await sync.mutate([
                                {
                                  'kind': selected == null
                                      ? 'orderPlaylists'
                                      : 'orderSongs',
                                  'playlistId': selected?.id ?? '',
                                  'order': order
                                }
                              ]);
                            }),
                            itemBuilder: (context, index) {
                              if (selected == null) {
                                final p = playlists[index];
                                return ListTile(
                                    key: ValueKey(p.id),
                                    title: Text(p.title),
                                    subtitle: Text('${p.songs.length} 首歌曲'),
                                    onTap: () =>
                                        setState(() => selectedId = p.id));
                              }
                              final song = selected.songs[index];
                              return ListTile(
                                  key: ValueKey(song['youtubeId']),
                                  title: Text(song['title']),
                                  subtitle: Text(song['artist']),
                                  onTap: () => run(() => play(selected, index)),
                                  trailing: Padding(
                                      padding: const EdgeInsets.only(right: 32),
                                      child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                                icon: const Icon(Icons.edit),
                                                tooltip: '編輯歌曲名稱',
                                                onPressed: () => run(() async {
                                                      final title = await input(
                                                          '歌曲名稱',
                                                          initial:
                                                              song['title']);
                                                      if (title != null)
                                                        await sync.mutate([
                                                          {
                                                            'kind': 'putSong',
                                                            'playlistId':
                                                                selected.id,
                                                            'song': {
                                                              ...song,
                                                              'title': title
                                                            }
                                                          }
                                                        ]);
                                                    })),
                                            IconButton(
                                                icon: const Icon(Icons
                                                    .remove_circle_outline),
                                                tooltip: '移除歌曲',
                                                onPressed: () =>
                                                    run(() => sync.mutate([
                                                          {
                                                            'kind':
                                                                'removeSong',
                                                            'playlistId':
                                                                selected.id,
                                                            'songId': song[
                                                                'youtubeId']
                                                          }
                                                        ]))),
                                          ])));
                            },
                          )),
              ]),
            ));
      });
}
