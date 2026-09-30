import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:spotube/services/kv_store/encrypted_kv_store.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'library_store.dart';
import 'drive_transport.dart';

const driveAppDataScope = 'https://www.googleapis.com/auth/drive.appdata';

class EvanDriveSync extends ChangeNotifier with WidgetsBindingObserver {
  static final instance = EvanDriveSync();
  final GoogleSignIn signIn = GoogleSignIn(scopes: [driveAppDataScope]);
  EvanLibraryStore? store;
  GoogleSignInAccount? account;
  String? error;
  bool syncing = false;
  bool ready = false;
  http.Client? _client;
  Timer? _debounce;
  Timer? _periodic;
  bool _foreground = true;
  bool _initialized = false;
  bool get active => ready && store!.enabled && store!.accountId == account?.id;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.addObserver(this);
    _periodic ??= Timer.periodic(const Duration(seconds: 45), (_) {
      if (_foreground && active) unawaited(sync());
    });
    try {
      error = null;
      if (!ready) {
        final directory = await getApplicationSupportDirectory();
        store = EvanLibraryStore(
            File('${directory.path}/evantube-playlists-v1.json'));
        await store!.load();
        ready = true;
      }
      if (store!.enabled) account = await signIn.signInSilently();
      if (active) unawaited(sync());
    } catch (_) {
      _initialized = false;
      error = '無法載入本機歌單或登入 Google；請重試。';
    }
    notifyListeners();
  }

  Future<void> connect() async {
    await disconnect();
    account = await signIn.signIn();
    notifyListeners();
  }

  Future<void> activate() async {
    final selected = account;
    if (!ready || selected == null) return;
    await store!.activate(selected.id);
    notifyListeners();
    await sync();
  }

  Future<void> disconnect() async {
    _debounce?.cancel();
    _client?.close();
    account = null;
    notifyListeners();
    if (ready) await store!.disconnect();
    await signIn.signOut();
    notifyListeners();
  }

  Future<void> mutate(List<Map<String, dynamic>> edits) async {
    if (!ready) throw StateError('Local library is unavailable.');
    await store!.mutate(edits);
    notifyListeners();
    _debounce?.cancel();
    if (active) _debounce = Timer(const Duration(seconds: 2), sync);
  }

  Future<void> sync() async {
    if (!active || syncing) return;
    syncing = true;
    error = null;
    notifyListeners();
    final selected = account!;
    final client = http.Client();
    _client = client;
    try {
      // Android Keystore keys cannot be restored onto a different device. A
      // failed secure-storage read must fail sync, never reuse a copied writer.
      final secure = EncryptedKvStoreService.storage;
      final key = 'evantube-drive-writer-${store!.deviceId}';
      var writer = await secure.read(key: key);
      if (writer == null) {
        writer = const Uuid().v4();
        await secure.write(key: key, value: writer);
      }
      if (!RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          .hasMatch(writer)) {
        throw const FormatException('Invalid secure Drive writer identity.');
      }
      final writerId = writer;
      final transport = EvanDriveTransport(client, () async {
        if (account?.id != selected.id || !active)
          throw StateError('Google account disconnected.');
        return selected.authHeaders;
      });
      await store!.sync(
          selected.id,
          () => transport.download().timeout(const Duration(seconds: 90)),
          (_, bytes) => transport.upload(writerId, bytes));
    } catch (_) {
      error = '同步失敗；本機變更已保留。請檢查網路、Google Drive 權限及 Android OAuth 設定後重試。';
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
      syncing = false;
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed && active) unawaited(sync());
  }
}
