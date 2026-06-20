# Standar Penulisan Repo ArahKarya

Standar struktur & gaya **README.md** untuk semua repo ArahKarya (NORA, FALCON, dst).
Tujuan: konsisten, profesional, mudah dipindai — bukan kesan "AI-generated".

Repo acuan: [`ArahKarya/nora`](https://github.com/ArahKarya/nora) ·
[`ArahKarya/falcon`](https://github.com/ArahKarya/falcon).

---

## Urutan wajib (atas → bawah)

1. **Title block terpusat** (`<div align="center">`)
   - H1: `# AKRONIM — Nama Lengkap` (pakai em-dash `—`, bukan hyphen)
   - Tagline 1 baris **tebal**: nilai inti produk, singkat
   - Deretan **badge** shields.io (lihat di bawah)
   - tutup `</div>`
2. **Blockquote** ringkasan tinggi: jenis produk + kolaborator
   `> Deskripsi singkat **multi-kata-kunci-tebal**.` `> Kolaborasi **X × Y**.`
3. **Paragraf pembuka** (1–2): jelaskan apa & kenapa, teknis tapi mengalir.
   Bold pada istilah kunci. Em-dash untuk klausa.
4. **`## ✨ Kenapa <Produk>`** — tabel `| Masalah | Solusi |`
5. **`## 📸 Tampilan`** — link demo live + tabel screenshot (kalau ada UI)
6. **`## 🏛️ Arsitektur`** — diagram ASCII di code block
7. **`## 🔁 Pipeline`** — alur 1 request/datagram, ASCII
8. Seksi domain-spesifik (kontrak, config, model — sesuai produk)
9. **`## 📁 Struktur Repo`** — tree di code block + komentar per-folder
10. **`## 🚀 Quickstart`** — perintah copy-paste, dengan catatan host
11. **`## ✅ Status`** — checklist `- [x]`/`- [ ]` fase/roadmap
12. **`## 🧱 Stack`** — ringkas teknologi
13. **Footer terpusat**: `<sub>© 2026 Arah Karya Sinergi (AKS) × NOZ</sub>`

> Tidak semua seksi wajib untuk tiap repo — ambil yang relevan, **urutannya tetap**.

---

## Badge (shields.io, `style=flat-square`)

Format: `[![Label](https://img.shields.io/badge/<KIRI>-<KANAN>-<HEX>?style=flat-square&logo=<opsional>&logoColor=white)](link)`

Warna sesuai peran (palet Hermes Dashboard):

| Peran | Hex | Contoh |
|---|---|---|
| Status / Live | `16C79A` (teal) | `Production-Live`, `Demo-Live` |
| Stack / License | `0F3460` (navy) | `Next.js 14 + FastAPI`, `License-MIT` |
| Bahasa (Python) | `3776AB` + `logo=python` | `Python-3.11` |
| Database / Transport | `FF6F61` (merah-koral) | `RAG-ChromaDB`, `Telemetry-UDP + WebSocket` |
| Engine / Akselerator custom | `7B2FBF` (ungu) | `Engine-NORA Agent Layer`, `Accelerator-FPGA GTP-U DPI` |

Susun 3 baris (≈ 2 badge/baris di mobile). Badge live **selalu pertama**, link ke demo.

---

## Gaya bahasa

- **Bahasa Indonesia** sebagai basis, istilah teknis **English** dibiarkan
  (mis. "line-rate", "push", "malformed-safe", "single source of truth").
- **Tebal** untuk konsep kunci & angka penting — jangan berlebihan, 1–3 per kalimat.
- **Em-dash `—`** untuk pemisah klausa / penjelas.
- Tone **teknis & langsung**, tidak bertele-tele, tidak marketing-hambar.
- **Copy bersumber dokumen produk** (BRD/PRD), bukan klaim generik.
  Klaim hambar ("solusi cerdas", "powerful") = kesan AI-generated → ditolak.
- Tabel & code block untuk apa pun yang terstruktur (port, API, byte-struct).

## Visual / desain (kalau ada UI di README)

- Screenshot di `docs/screenshots/`, ditampilkan via tabel 2-kolom.
- UI mengikuti **Hermes Dashboard**: flat, solid, border 1px, sudut tajam,
  mono untuk angka — **tanpa glow/neon/wire** (lihat skill `arahkarya-login-page-design`).

---

## Checklist sebelum commit README

- [ ] Title `AKRONIM — Nama Lengkap` (em-dash), terpusat
- [ ] Tagline 1 baris tebal
- [ ] Badge: status-live pertama, warna sesuai peran, `flat-square`
- [ ] Blockquote ringkasan + kolaborator
- [ ] Em-dash & bold dipakai wajar (bukan tiap kata)
- [ ] Klaim bersumber BRD/PRD, bukan generik
- [ ] Tabel/code block untuk data terstruktur
- [ ] Footer copyright terpusat
- [ ] `LICENSE` ada bila badge License merujuknya

---

© Arah Karya Sinergi (AKS) — standar internal, ikuti di semua repo.
