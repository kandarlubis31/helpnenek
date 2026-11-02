# Project: backup_foto (helpnenek)

## Ringkasan

Aplikasi Flutter **"Kirim Foto"** — dibuat untuk membantu anggota keluarga yang lebih tua ("Nenek") mengirim otomatis semua foto & video dari folder DCIM ke folder aplikasi di **Dropbox** milik keluarga.

- **Developer:** Salah satu anggota keluarga (Elu)
- **Pengguna:** Nenek / anggota keluarga yang lebih tua
- **Penerima foto:** Keluarga (via Dropbox)

## Arsitektur

Semua logika ada di **satu file**: `lib/main.dart` (~550 baris).

### Alur Aplikasi (State Machine)

```
checking → needPermission → sending → done
                              ↘ error ↗ (retry)
```

| Phase | Deskripsi |
|-------|-----------|
| `checking` | Memeriksa izin akses galeri |
| `needPermission` | Meminta izin; tombol "IZINKAN AKSES" / "PILIH ULANG FOTO" |
| `sending` | Progress bar: mengirim foto satu per satu ke Dropbox |
| `done` | Ringkasan: terkirim / sudah dikirim / gagal |
| `error` | Pesan error + tombol "COBA LAGI" |

### Komponen Utama

- **`KirimFotoApp`** — `MaterialApp` dengan tema hijau (Material 3)
- **`HomePage`** — StatefulWidget utama, mengelola semua phase
- **`_BigMessage`** — Widget reusable untuk card berisi ikon, judul, deskripsi, dan tombol
- **`_PermissionView`** — Tampilan izin galeri
- **`_SendingView`** — Progress bar + nama file sedang diproses
- **`_DoneView`** — Ringkasan hasil pengiriman
- **`_ErrorView`** — Tampilan error
- **`_BigButton`** — Tombol hijau besar dengan ikon

### Dependency & Layanan

| Package | Fungsi |
|---------|--------|
| `photo_manager` | Mengakses foto/video di galeri (DCIM) |
| `http` | Upload file ke Dropbox API |
| `shared_preferences` | Menyimpan daftar file yang sudah terkirim (hindari duplikat) |
| `cupertino_icons` | Ikon iOS-style |

### Mekanisme Pengiriman ke Dropbox

1. **Ambil semua asset** dari folder DCIM via `photo_manager`
2. **Filter** file yang sudah pernah terkirim (berdasarkan judul file) via `shared_preferences`
3. **Upload** satu per satu ke Dropbox API (`/2/files/upload`) dengan retry 3x jika jaringan tidak stabil
4. **Simpan** daftar file yang sudah terkirim agar tidak terkirim ulang
5. **Token Dropbox** di-inject via build-time: `flutter build apk --release --dart-define=DROPBOX_TOKEN=sl.xxx`

### Penerima Foto (Komputer)

`tool/dropbox_receiver.dart` — Script Dart yang berjalan di komputer keluarga:
- Polling Dropbox tiap 10 detik
- Mengunduh file baru ke folder `./received_photos`
- Menghapus file dari Dropbox setelah diunduh (hemat space)

Jalankan: `dart run tool/dropbox_receiver.dart --token <TOKEN>`

## Build & Deploy

```bash
# Build APK
flutter build apk --release --dart-define=DROPBOX_TOKEN=sl.xxx

# Jalankan receiver (di komputer)
dart run tool/dropbox_receiver.dart --token <TOKEN>
```

## Struktur File

```
lib/
  main.dart              # Seluruh logika aplikasi (1 file)
test/
  widget_test.dart       # Test dasar: app tidak crash
tool/
  dropbox_receiver.dart  # Script receiver untuk komputer
pubspec.yaml             # Dependencies & konfigurasi Flutter
```

## Detail Teknis

- **Version:** 1.0.0+1
- **Dart SDK:** ^3.11.1
- **Flutter lints:** ^6.0.0
- **Platform:** Android (utama, via `photo_manager`)
- **Konstanta lingkungan:** `kDropboxToken` (via `--dart-define`), `kSentPrefsKey = 'sent_files'`
- **Retry:** 3 percobaan dengan delay 2 detik saat upload gagal karena jaringan
- **Batch:** 1000 asset per halaman saat memuat dari MediaStore
- **Penanganan error:** TokenException (401/403) langsung dilempar; error lain dihitung sebagai "gagal" tapi dilanjutkan

## Progress Assessment

**Status: Berfungsi penuh (Feature-complete)**

- ✅ Akses galeri (termasuk mode limited/partial di Android 14)
- ✅ Upload foto/video ke Dropbox satu per satu
- ✅ Deteksi file duplikat (tidak mengirim ulang)
- ✅ Retry otomatis saat jaringan tidak stabil
- ✅ UI yang ramah pengguna (tombol besar, teks jelas, progress bar)
- ✅ Pesan error yang jelas dan bisa diulang
- ✅ Tracking hasil pengiriman (terkirim/sudah dikirim/gagal)
- ✅ Script penerima di komputer
- ✅ Test dasar tersedia

## Catatan Penting

- **Token harus diisi saat build APK** — tidak bisa diubah tanpa rebuild
- **Tidak ada layar settings/preferences** — semuanya otomatis saat aplikasi dibuka
- **Hanya asset DCIM** yang diambil (bukan semua galeri)
- **File asli tidak dihapus** dari perangkat — aman untuk Nenek
- **Tidak ada notifikasi/background** — pengiriman hanya terjadi saat aplikasi terbuka

## Ide Pengembangan Masa Depan

- [ ] Notifikasi background agar pengiriman otomatis tanpa buka app
- [ ] Endpoint khusus Dropbox untuk Nenek (berbeda dengan keluarga)
- [ ] Layar settings untuk mengubah/mengatur ulang token
- [ ] Pilihan folder tujuan di Dropbox
- [ ] Kompresi/resize foto sebelum upload agar hemat space
- [ ] Enkripsi file sebelum upload
- [ ] Support iOS
- [ ] Multi-platform (Windows/macOS untuk receiver)
