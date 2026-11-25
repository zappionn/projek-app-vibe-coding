# Panduan Setup TeamFair (Fase 0 & Deploy Fase A Supabase)

Dokumen ini memandu penyiapan toolchain Windows dan layanan gratis sebelum membangun proyek Flutter (`app/`) menjadi `.apk`.

---

## 1. Fase 0 — Instalasi Toolchain Lokal (Windows)

Berdasarkan pemeriksaan lingkungan awal, `git`, `flutter`, `dart`, dan `supabase` belum terpasang di PATH Windows Anda. Jalankan langkah berikut:

1. **Git**:
   ```powershell
   winget install --id Git.Git -e --source winget
   ```
2. **Flutter SDK & Android Studio (JDK 17 + Android SDK)**:
   - Unduh dan ekstrak Flutter SDK Stable ke `C:\src\flutter`, lalu tambahkan `C:\src\flutter\bin` ke **User PATH**.
   - Instal **Android Studio** (atau gunakan `winget install Google.AndroidStudio`) dan pasang **Android SDK Platform** + **Android SDK Build-Tools** + **Android SDK Command-line Tools**.
   - Jalankan verifikasi hingga hijau untuk target Android:
     ```powershell
     flutter doctor --android-licenses
     flutter doctor
     ```
3. **Supabase CLI** (opsional lewat `scoop` atau `npx`):
   ```powershell
   npx supabase --version
   ```

---

## 2. Penyiapan Layanan Cloud Gratis

### A. Supabase Free Tier
1. Buat project baru di Supabase Dashboard (region terdekat: **Singapore**).
2. Salin **Project URL** dan **anon public key** (untuk `--dart-define` Flutter nanti).
3. Jalankan migrasi SQL secara berurutan di **SQL Editor** (atau via `supabase db push`):
   - `supabase/migrations/001_schema_core.sql`
   - `supabase/migrations/002_rls_policies.sql`
   - `supabase/migrations/003_triggers_and_rpcs.sql`
   - `supabase/migrations/004_storage_buckets.sql`
   - `supabase/migrations/005_badges_in_finalization.sql`
4. Di **Authentication -> Providers**, aktifkan **Email** dan **Google**.

### B. Google Cloud Console (Google Sign-In)
1. Buat OAuth 2.0 Client ID tipe **Web Application** -> masukkan Redirect URI dari Supabase (`https://<PROJECT_REF>.supabase.co/auth/v1/callback`) -> tempel Client ID & Secret ke Supabase Auth Google Provider.
2. Buat OAuth 2.0 Client ID tipe **Android** menggunakan package name aplikasi (mis. `id.ac.unila.teamfair`) dan SHA-1 keystore debug/release.

### C. Firebase Spark Plan (FCM Gratis)
1. Buat project gratis di Firebase Console dan daftarkan aplikasi Android (`id.ac.unila.teamfair`).
2. Unduh `google-services.json` (nanti diletakkan di `app/android/app/google-services.json`).
3. Di **Project Settings -> Service Accounts**, buat Private Key JSON untuk FCM HTTP v1 API.

### D. Google AI Studio (`GEMINI_API_KEY`)
1. Buat API key gratis di Google AI Studio.
2. Salin `supabase/.env.example` menjadi `supabase/.env`, isi semua nilai rahasia, lalu set ke Supabase:
   ```powershell
   npx supabase login
   npx supabase link --project-ref <PROJECT_REF>
   npx supabase secrets set --env-file supabase/.env
   npx supabase functions deploy analyze-message
   npx supabase functions deploy evaluate-file-diff
   npx supabase functions deploy copilot-assistant
   npx supabase functions deploy send-push-fcm
   npx supabase functions deploy sync-deadlines
   npx supabase functions deploy verify-report
   ```

---

## 3. Lanjut ke Fase B (Inisialisasi Proyek Flutter)

Setelah `flutter doctor` siap, jalankan dari root folder `d:\SEMESTER 5\ANTIGRAVITY APK`:
```powershell
flutter create --org id.ac.unila --project-name teamfair app
```
Lalu beri tahu Antigravity untuk mulai menuliskan modul Flutter Fase B–F dan menguji build `.apk`.
