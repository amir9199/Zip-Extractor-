# ⚡ Auto Zip Extractor

A fast, standalone archive extraction tool for Windows that extracts all images and files directly from your archives (`.rar`, `.zip`, `.7z`, `.tar`, `.tar.gz`, `.tgz`, `.gz`, `.bz2`, `.xz`) into your **dedicated folder** without creating unnecessary subfolders.

---

## 🚀 How to Run (1-Click)

Bas folder mein ja kar **double-click** karein:
- **`AutoZipExtractor.bat`** — Direct GUI open ho jayegi.

---

## ✨ Features & Interface

### 1. 🎯 Dedicated Destination Folder & Lock Protection
- **`📁 Browse...` Button**: Apna destination folder chunein jahan files save honi hain.
- **`👁` Eye Lock Toggle**: Box ke andar eye icon par click karke path ko **Lock** kar sakte hain taake galti se hath lagne par path kharab na ho. Jab change karna ho to dubara click karke **Unlock** kar lein.

### 2. 🖼 Direct Extraction (No Extra Subfolders)
- **Direct Extraction (Default)**: Archive ke naam ka koi extra subfolder nahi banta (jaise `B100-S1_Part 6` nahi banega). Archive ke andar jo bhi `.png` images ya files hain, woh **seedhi dedicated folder mein nikal ayengi**.
- **Batch Multi-Files Extraction**: Chahe aap 10, 50, ya 100 `.rar` / `.zip` files ek sath select karein, un sab ke andar ki saari images seedhi dedicated folder mein aakar save ho jayengi.
- **Duplicate Auto-Rename**: Agar alag alag archives mein same naam ki images hon, to tool unko `image (1).png`, `image (2).png` karke save karega taake koi image overwrite na ho.

### 3. ⚡ High-Speed Zero-Delay Engine & Live Timer
- **High-Speed Decompression Engine**: 
  - RAR ke liye official 64-bit multi-threaded **Alexander Roshal UnRAR native C++ engine** with `-inul` quiet switch (zero pipe delay).
  - ZIP ke liye 1MB memory buffer stream (`shutil.copyfileobj(..., length=1024*1024)`).
  - UI updates throttle kiye gaye hain taake extraction ke doran GUI lag ya delay bilkul na aye.
- **Live Extraction Timer**: Buttons ke sath exact time show hota hai ke extraction kitne seconds mein complete hui (e.g. `⏱️ Extracted in 0.35s`).

### 4. 📜 History
- Past extractions ka record aur 1-click **"Open Selected Folder"** button.

---

## 📁 Files in Folder (Sirf 2 Files)

1. **`AutoZipExtractor.bat`** — Pura standalone tool (Script + GUI + Extraction Engine sab ek hi file mein).
2. **`README.md`** — Guide document.
