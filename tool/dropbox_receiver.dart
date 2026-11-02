// Penerima foto: narik semua file dari folder app Dropbox ke ./received_photos,
// lalu menghapusnya dari Dropbox biar space-nya kosong terus.
//
// Cara jalanin (pakai Dart yang sudah ada di Flutter SDK, gak install apa-apa):
//   dart run tool/dropbox_receiver.dart --token <DROPBOX_TOKEN>
// atau lewat env:  DROPBOX_TOKEN=sl.xxx dart run tool/dropbox_receiver.dart
//
// Biarkan jalan di komputer elu — tiap 10 detik dia cek file baru.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  var token = _arg(args, '--token') ?? Platform.environment['DROPBOX_TOKEN'];
  if (token == null || token.isEmpty) {
    stdout.writeln(
      'Gunakan: dart run tool/dropbox_receiver.dart --token <DROPBOX_TOKEN>',
    );
    exit(1);
  }

  final outDir = Directory('received_photos');
  await outDir.create(recursive: true);
  stdout.writeln('Menunggu foto baru di Dropbox... (Ctrl+C untuk berhenti)');
  stdout.writeln('File akan disimpan di: ${outDir.absolute.path}');

  while (true) {
    try {
      await _poll(token, outDir);
    } catch (e) {
      stdout.writeln('Error: $e');
    }
    await Future.delayed(const Duration(seconds: 10));
  }
}

Future<void> _poll(String token, Directory outDir) async {
  final files = await _listFiles(token);
  for (final path in files) {
    final name = path.split('/').last;
    final target = File('${outDir.path}/$name');
    if (await target.exists()) {
      stdout.writeln('Lewati (sudah ada): $name');
      await _delete(token, path);
      continue;
    }
    stdout.writeln('Mengunduh: $name');
    final bytes = await _download(token, path);
    await target.writeAsBytes(bytes, flush: true);
    await _delete(token, path);
    stdout.writeln('Tersimpan: ${target.path}');
  }
}

/// Daftar semua file (path) di root folder app Dropbox.
Future<List<String>> _listFiles(String token) async {
  final client = HttpClient();
  try {
    final result = <String>[];
    var cursor = '';
    do {
      final isContinue = cursor.isNotEmpty;
      final url = isContinue
          ? 'https://api.dropboxapi.com/2/files/list_folder/continue'
          : 'https://api.dropboxapi.com/2/files/list_folder';
      final body =
          isContinue ? '{"cursor":"$cursor"}' : '{"path":"","recursive":true}';

      final req = await client.postUrl(Uri.parse(url));
      req.headers.set('Authorization', 'Bearer $token');
      req.headers.set('Content-Type', 'application/json');
      req.write(body);
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        throw Exception('list_folder gagal (${resp.statusCode}): $text');
      }

      final json = jsonDecode(text) as Map<String, dynamic>;
      for (final entry in (json['entries'] as List)) {
        final e = entry as Map<String, dynamic>;
        if (e['.tag'] == 'file') {
          result.add(e['path_display'] as String);
        }
      }
      cursor = json['cursor'] as String? ?? '';
      if (json['has_more'] != true) break;
    } while (cursor.isNotEmpty);
    return result;
  } finally {
    client.close();
  }
}

Future<List<int>> _download(String token, String path) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(
      Uri.parse('https://content.dropboxapi.com/2/files/download'),
    );
    req.headers.set('Authorization', 'Bearer $token');
    req.headers.set(
      'Dropbox-API-Arg',
      jsonEncode({'path': path}),
    );
    final resp = await req.close();
    if (resp.statusCode != 200) {
      final text = await resp.transform(utf8.decoder).join();
      throw Exception('download gagal (${resp.statusCode}): $text');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } finally {
    client.close();
  }
}

Future<void> _delete(String token, String path) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(
      Uri.parse('https://api.dropboxapi.com/2/files/delete'),
    );
    req.headers.set('Authorization', 'Bearer $token');
    req.headers.set('Content-Type', 'application/json');
    req.write(jsonEncode({'path': path}));
    final resp = await req.close();
    await resp.drain<void>();
    if (resp.statusCode != 200) {
      throw Exception('delete gagal (${resp.statusCode})');
    }
  } finally {
    client.close();
  }
}

String? _arg(List<String> args, String name) {
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == name) return args[i + 1];
  }
  return null;
}
