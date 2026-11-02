import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Token Dropbox (dari akun keluarga/elu). Diisi saat build APK:
///   flutter build apk --release --dart-define=DROPBOX_TOKEN=sl.xxx
const String kDropboxToken = String.fromEnvironment('DROPBOX_TOKEN');

/// Key penyimpanan daftar file yang sudah terkirim.
const String kSentPrefsKey = 'sent_files';

void main() {
  runApp(const KirimFotoApp());
}

class KirimFotoApp extends StatelessWidget {
  const KirimFotoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kirim Foto',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      ),
      home: const HomePage(),
    );
  }
}

enum _Phase { checking, needPermission, sending, done, error }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  _Phase _phase = _Phase.checking;
  bool _limited = false; // Android 14: cuma sebagian foto yang dipilih
  int _total = 0;
  int _processed = 0;
  int _sent = 0;
  int _skipped = 0;
  int _failed = 0;
  String _currentFile = '';
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _refreshPermission();
  }

  // ---------------------------------------------------------------- izin

  Future<void> _refreshPermission() async {
    setState(() => _phase = _Phase.checking);
    try {
      final state = await PhotoManager.getPermissionState(
        requestOption: const PermissionRequestOption(),
      );
      if (!mounted) return;
      final granted = state.hasAccess;
      setState(() {
        _limited = state == PermissionState.limited;
        _phase = granted ? _Phase.sending : _Phase.needPermission;
      });
      // Langsung kirim begitu izin sudah diberikan.
      if (granted) {
        _startSending();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Tidak bisa memeriksa izin. Coba buka aplikasi lagi ya.';
        _phase = _Phase.error;
      });
    }
  }

  Future<void> _requestAccess() async {
    try {
      await PhotoManager.requestPermissionExtend();
    } catch (_) {
      // Diabaikan; cek ulang di bawah.
    }
    await _refreshPermission();
  }

  Future<void> _reselectPhotos() async {
    try {
      await PhotoManager.presentLimited(type: RequestType.common);
    } catch (_) {
      // Tidak tersedia di Android lama; abaikan.
    }
    await _refreshPermission();
  }

  // ---------------------------------------------------------------- kirim

  Future<void> _startSending() async {
    setState(() {
      _phase = _Phase.sending;
      _total = 0;
      _processed = 0;
      _sent = 0;
      _skipped = 0;
      _failed = 0;
      _currentFile = '';
    });
    try {
      final result = await _sendPhotos((processed, total, name) {
        if (!mounted) return;
        setState(() {
          _processed = processed;
          _total = total;
          _currentFile = name;
        });
      });
      if (!mounted) return;
      setState(() {
        _sent = result.sent;
        _skipped = result.skipped;
        _failed = result.failed;
        _phase = _Phase.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '$e';
        _phase = _Phase.error;
      });
    }
  }

  Future<_SendResult> _sendPhotos(
    void Function(int processed, int total, String name) onProgress,
  ) async {
    if (kDropboxToken.isEmpty) {
      throw Exception(
        'Token Dropbox belum diisi saat build APK. Minta bantuan keluarga ya.',
      );
    }

    // Pastikan data MediaStore selalu yang paling baru.
    await PhotoManager.clearFileCache();

    final assets = await _collectDcimAssets();
    final prefs = await SharedPreferences.getInstance();
    final sent = (prefs.getStringList(kSentPrefsKey) ?? <String>[]).toSet();

    final total = assets.length;
    var sentCount = 0;
    var skipped = 0;
    var failed = 0;
    onProgress(0, total, '');

    for (final asset in assets) {
      final title = asset.title ?? 'foto';

      if (sent.contains(title)) {
        skipped++;
        onProgress(sentCount + skipped + failed, total, title);
        continue;
      }

      try {
        final file = await asset.file;
        if (file == null) {
          failed++;
        } else {
          await _uploadToDropbox(file, title);
          sent.add(title);
          await prefs.setStringList(kSentPrefsKey, sent.toList());
          sentCount++;
        }
      } on _TokenException {
        rethrow; // Token salah — hentikan dan tampilkan pesan jelas.
      } catch (_) {
        failed++;
      }
      onProgress(sentCount + skipped + failed, total, title);
    }

    return _SendResult(sent: sentCount, skipped: skipped, failed: failed);
  }

  /// Upload satu file ke folder app Dropbox. Ada percobaan ulang otomatis
  /// buat jaringan yang kurang stabil.
  Future<void> _uploadToDropbox(File file, String name) async {
    final bytes = await file.readAsBytes();
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final resp = await http.post(
          Uri.parse('https://content.dropboxapi.com/2/files/upload'),
          headers: {
            'Authorization': 'Bearer $kDropboxToken',
            'Content-Type': 'application/octet-stream',
            'Dropbox-API-Arg': jsonEncode({
              'path': '/$name',
              'mode': 'add',
              'autorename': false,
            }),
          },
          body: bytes,
        );
        if (resp.statusCode == 200 || resp.statusCode == 201) return;
        if (resp.statusCode == 409) return; // Sudah ada di Dropbox = terkirim.
        if (resp.statusCode == 401 || resp.statusCode == 403) {
          throw const _TokenException();
        }
      } on _TokenException {
        rethrow;
      } catch (_) {
        // Jaringan bermasalah — coba lagi.
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    throw Exception('Gagal mengirim $name');
  }

  /// Semua asset (foto + video) yang ada di folder DCIM.
  Future<List<AssetEntity>> _collectDcimAssets() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: false,
    );
    final dcimPaths = <AssetPathEntity>[];
    for (final p in paths) {
      final rel = (await p.relativePathAsync ?? '').toUpperCase();
      final name = p.name.toUpperCase();
      if (rel.contains('DCIM') || name == 'CAMERA') {
        dcimPaths.add(p);
      }
    }
    return _collectAssetsFromPaths(dcimPaths);
  }

  Future<List<AssetEntity>> _collectAssetsFromPaths(
    List<AssetPathEntity> paths,
  ) async {
    final assets = <AssetEntity>[];
    for (final path in paths) {
      final count = await path.assetCountAsync;
      const pageSize = 1000;
      for (var start = 0; start < count; start += pageSize) {
        final end = start + pageSize > count ? count : start + pageSize;
        final page = await path.getAssetListRange(start: start, end: end);
        assets.addAll(page);
      }
    }
    return assets;
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: _buildBody(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _Phase.checking:
        return const _BigMessage(
          icon: Icons.hourglass_top_rounded,
          title: 'Sebentar ya...',
          body: '',
        );
      case _Phase.needPermission:
        return _PermissionView(
          limited: _limited,
          onAllow: _requestAccess,
          onReselect: _reselectPhotos,
        );
      case _Phase.sending:
        return _SendingView(
          processed: _processed,
          total: _total,
          currentFile: _currentFile,
        );
      case _Phase.done:
        return _DoneView(
          sent: _sent,
          skipped: _skipped,
          failed: _failed,
          onAgain: _startSending,
        );
      case _Phase.error:
        return _ErrorView(message: _errorMessage, onRetry: _refreshPermission);
    }
  }
}

// ---------------------------------------------------------------- widgets

class _BigMessage extends StatelessWidget {
  const _BigMessage({
    required this.icon,
    required this.title,
    required this.body,
    this.child,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 84, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                body,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 19, height: 1.5),
              ),
            ],
            if (child != null) ...[
              const SizedBox(height: 28),
              child!,
            ],
          ],
        ),
      ),
    );
  }
}

class _PermissionView extends StatelessWidget {
  const _PermissionView({
    required this.limited,
    required this.onAllow,
    required this.onReselect,
  });

  final bool limited;
  final VoidCallback onAllow;
  final VoidCallback onReselect;

  @override
  Widget build(BuildContext context) {
    final body = limited
        ? 'Kamu baru memilih sebagian foto. Klik "PILIH ULANG FOTO" lalu '
            'pilih "Izinkan semua foto" biar semua foto ikut terkirim.'
        : 'Aplikasi ini untuk mengirim semua foto & video dari folder DCIM '
            'ke keluarga.\n\nFoto asli tidak dihapus, jadi aman.\n\n'
            'Klik tombol hijau di bawah, lalu pilih "Izinkan" ya.';
    return _BigMessage(
      icon: Icons.photo_library_rounded,
      title: 'Halo Nenek! 👋',
      body: body,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _BigButton(label: 'IZINKAN AKSES', icon: Icons.check_circle, onPressed: onAllow),
          if (limited) ...[
            const SizedBox(height: 14),
            _BigButton(label: 'PILIH ULANG FOTO', icon: Icons.photo_library_outlined, onPressed: onReselect),
          ],
        ],
      ),
    );
  }
}

class _SendingView extends StatelessWidget {
  const _SendingView({
    required this.processed,
    required this.total,
    required this.currentFile,
  });

  final int processed;
  final int total;
  final String currentFile;

  @override
  Widget build(BuildContext context) {
    final double progress = total > 0 ? (processed / total).clamp(0.0, 1.0) : 0.0;
    return _BigMessage(
      icon: Icons.cloud_upload_rounded,
      title: 'Sedang mengirim...',
      body: total > 0
          ? 'Foto ke-$processed dari $total'
          : 'Memeriksa foto...',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 14,
            ),
          ),
          const SizedBox(height: 14),
          if (currentFile.isNotEmpty)
            Text(
              currentFile,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, color: Colors.black54),
            ),
          const SizedBox(height: 14),
          const Text(
            'Mohon jangan tutup aplikasi ini ya 🙏',
            style: TextStyle(fontSize: 15),
          ),
        ],
      ),
    );
  }
}

class _DoneView extends StatelessWidget {
  const _DoneView({
    required this.sent,
    required this.skipped,
    required this.failed,
    required this.onAgain,
  });

  final int sent;
  final int skipped;
  final int failed;
  final VoidCallback onAgain;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      if (sent > 0) 'Foto terkirim: $sent',
      if (skipped > 0) 'Sudah pernah terkirim: $skipped',
      if (failed > 0) 'Gagal: $failed (bisa dicoba lagi)',
      if (sent == 0 && skipped == 0 && failed == 0) 'Tidak ada foto baru.',
    ];
    return _BigMessage(
      icon: Icons.celebration_rounded,
      title: 'Selesai! 🎉',
      body: '${lines.join('\n')}\n\nFoto baru nanti otomatis terkirim '
          'setiap aplikasi dibuka.',
      child: _BigButton(label: 'ULANGI LAGI', icon: Icons.refresh, onPressed: onAgain),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _BigMessage(
      icon: Icons.error_rounded,
      title: 'Ada masalah 😢',
      body: message,
      child: _BigButton(label: 'COBA LAGI', icon: Icons.refresh, onPressed: onRetry),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 30),
        label: Text(label, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(68),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- result

class _SendResult {
  const _SendResult({
    required this.sent,
    required this.skipped,
    required this.failed,
  });

  final int sent;
  final int skipped;
  final int failed;
}

/// Token Dropbox salah / tidak punya izin.
class _TokenException implements Exception {
  const _TokenException();

  @override
  String toString() =>
      'Token Dropbox tidak valid. Minta bantuan keluarga untuk memperbaiki.';
}
