# 🔥 Unity Firebase Auto Setup

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Unity-lightgrey.svg)
![Firebase](https://img.shields.io/badge/Firebase-Unity-orange.svg)
![Auto Setup](https://img.shields.io/badge/auto--setup-enabled-brightgreen.svg)

Automatically download and configure **Firebase SDK for Unity** without bloating your Git repository.  
Supports macOS, Windows, and CI/CD environments (Jenkins, GitHub Actions, etc).

---

## 🤔 Why not store Firebase SDK in Git?

Firebase Unity SDK packages are **very large** (hundreds of MBs)  
and contain platform-specific binaries (Android, iOS, Editor).

Instead of bloating your repo, this tool:
- Download them on demand
- Keeps your Git history small
- Guarantees reproducible builds across all environments

---

## ✨ Features

✅ Downloads official `.tgz` packages from Google Game Package Registry  
✅ Adds dependencies automatically to `Packages/manifest.json`  
✅ Handles **External Dependency Manager (EDM4U)** setup  
✅ Auto-cleans unused Firebase SDKs  
✅ Works on **macOS / Windows** and in **CI/CD** pipelines  
✅ Configurable through a single JSONC file  
✅ Optional flags for `--force`, `--channel=latest`, `--no-cleanup`

---

## 📂 Project Structure

```
unity-firebase-auto-setup/
├── tools/
│   ├── fb_install.sh          # macOS/Linux installer
│   ├── fb_install.ps1         # Windows PowerShell installer
│   └── firebase_tgz.config.jsonc  # configuration file
└── README.md
└── LICENSE
```

---

## ⚙️ Configuration — `tools/firebase_tgz.config.jsonc`

The configuration file defines where and which Firebase SDKs are installed.

### 🔗 base_url
**Type:** string  
**Default:** `https://dl.google.com/games/registry/unity/`  
Base URL of the Google Game Package Registry.  
You rarely need to change this unless hosting your own registry.

---

### 📁 dest_root
**Type:** string  
**Example:** `ThirdParty/firebase`  
Directory where downloaded `.tgz` packages will be unpacked.  
Usually ignored in Git (`.gitignore`).

---

### 📄 manifest
**Type:** string  
**Example:** `Packages/manifest.json`  
Path to Unity’s `manifest.json` file.  
The installer updates this file automatically.

---

### 📦 modules
**Type:** array of objects  
Each module entry controls a single Firebase or EDM4U package.

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Package identifier, e.g. `com.google.firebase.app` |
| `version` | string | Version number, e.g. `12.10.1` |
| `enabled` | boolean | `true` → install / `false` → remove (unless `--no-cleanup`) |

**Download URL format:**
```
<base_url>/<id>/<id>-<version>.tgz
```

**Example:**
```jsonc
"modules": [
  { "id": "com.google.external-dependency-manager", "version": "1.2.186", "enabled": true },
  { "id": "com.google.firebase.app", "version": "12.10.1", "enabled": true },
  { "id": "com.google.firebase.auth", "version": "12.10.1", "enabled": true },
  { "id": "com.google.firebase.functions", "version": "12.10.1", "enabled": false }
]
```

> ⚠️ Always keep **`com.google.firebase.app`** enabled — it’s required by most Firebase modules.

---

## 🧰 Usage

### macOS / Linux
```bash
bash tools/fb_install.sh                 # install/update + cleanup
bash tools/fb_install.sh --no-cleanup    # skip cleanup
bash tools/fb_install.sh --force         # reinstall everything
bash tools/fb_install.sh --channel=latest # try latest version (fallback to stable)
```

### Windows PowerShell
```powershell
powershell -ExecutionPolicy Bypass -File tools\fb_install.ps1
powershell -ExecutionPolicy Bypass -File tools\fb_install.ps1 -NoCleanup
powershell -ExecutionPolicy Bypass -File tools\fb_install.ps1 -Force
powershell -ExecutionPolicy Bypass -File tools\fb_install.ps1 -Channel latest
```

---

## 🧹 Automatic Cleanup

By default, the installer **removes all Firebase SDKs not listed in your config**:
- Removes entries from `Packages/manifest.json`
- Deletes unused folders in `ThirdParty/firebase/`

You can skip cleanup with the flag:
```bash
bash tools/fb_install.sh --no-cleanup
```

---

## 🚀 CI/CD Integration

Add this to your CI before building the project:

**Linux/macOS Agent**
```bash
bash tools/fb_install.sh --channel=stable
```

**Windows Agent**
```powershell
powershell -ExecutionPolicy Bypass -File tools\fb_install.ps1
```

This ensures the latest required Firebase modules are downloaded and ready for Unity build.

---

## 🧠 License

This project is licensed under the **MIT License** — see [LICENSE](LICENSE).

---

## 🌐 Links

- 🔗 [Firebase Unity SDK Official Page](https://firebase.google.com/docs/unity/setup)
- 🔗 [Firebase Unity SDK on GitHub](https://github.com/firebase/firebase-unity-sdk)
- 🔗 [Google Game Package Registry](https://developers.google.com/unity/archive)