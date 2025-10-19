#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Firebase Auto Setup for Unity (macOS/Linux; Bash 3 compatible)
#  Usage:
#    bash tools/fb_install.sh [config.jsonc] [--force|-f] [--no-cleanup]
#    (flags can be in any order; first non-flag arg is config path)
# ============================================================

# Defaults
CONFIG_FILE="Unity-Firebase-Auto-Setup/tools/firebase_tgz.config.jsonc"
FORCE=0
NO_CLEANUP=0

# Parse args: first non-flag is CONFIG_FILE; flags anywhere
for arg in "$@"; do
  case "$arg" in
    --force|-f)        FORCE=1 ;;
    --no-cleanup)      NO_CLEANUP=1 ;;
    --*)               echo "Unknown flag: $arg"; exit 2 ;;
    *)                 CONFIG_FILE="$arg" ;;
  esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config not found: $CONFIG_FILE"
  echo "Expected at Unity-Firebase-Auto-Setup/tools/firebase_tgz.config.jsonc (or pass path as 1st arg)."
  exit 1
fi

# Temp files
ASSIGN_FILE="$(mktemp)"
MODULES_FILE="$(mktemp)"
PY_OUT_FILE="$(mktemp)"

# Produce assignments and module lines (BASE_URL/DEST_ROOT/MANIFEST + MODULE <id> <version> <enabled>)
python3 - "$CONFIG_FILE" >"$PY_OUT_FILE" <<'PY'
import sys, json, re, pathlib
p = pathlib.Path(sys.argv[1])
txt = p.read_text(encoding='utf-8')
txt = re.sub(r'^\s*//.*$', '', txt, flags=re.M)  # strip // comments
cfg = json.loads(txt)

print(f'BASE_URL="{cfg["base_url"].rstrip("/")}/"')
print(f'DEST_ROOT="{cfg["dest_root"]}"')
print(f'MANIFEST="{cfg["manifest"]}"')

print("MODULES_START")
for m in cfg.get("modules", []):
    mid = (m.get("id") or "").strip().replace(" ", "")
    ver = (m.get("version") or "").strip()
    en  = "true" if bool(m.get("enabled")) else "false"
    print("MODULE %s %s %s" % (mid, ver, en))
print("MODULES_END")
PY

# Split Python output: eval only assignments; keep MODULE lines
in_block=0
while IFS= read -r line; do
  case "$line" in
    BASE_URL=*|DEST_ROOT=*|MANIFEST=*) echo "$line" >>"$ASSIGN_FILE" ;;
    MODULES_START) in_block=1 ;;
    MODULES_END)   in_block=0 ;;
    MODULE\ *)     [[ $in_block -eq 1 ]] && echo "$line" >>"$MODULES_FILE" ;;
    *) : ;;
  esac
done < "$PY_OUT_FILE"
rm -f "$PY_OUT_FILE"

# Apply assignments
# shellcheck disable=SC1090
source "$ASSIGN_FILE"
rm -f "$ASSIGN_FILE"

: "${BASE_URL:?BASE_URL not set}"
: "${DEST_ROOT:?DEST_ROOT not set}"
: "${MANIFEST:?MANIFEST not set}"

mkdir -p "$DEST_ROOT"

# Collect modules (Bash 3 friendly; no associative arrays)
ALL_IDS=()
ALL_VERS=()
ENABLED_IDS=()

# Parse "MODULE <id> <version> <enabled>"
while IFS= read -r line; do
  set -- $line
  # $1=MODULE $2=id $3=version $4=enabled
  id="$2"; ver="$3"; enabled="$4"
  [[ -z "$id" ]] && continue

  ALL_IDS+=("$id")
  ALL_VERS+=("$ver")

  if [[ "$enabled" == "true" ]]; then
    if [[ -z "$ver" ]]; then
      echo "ERROR: Version is required for enabled module: $id"
      rm -f "$MODULES_FILE"
      exit 1
    fi
    ENABLED_IDS+=("$id")
  fi
done < "$MODULES_FILE"
rm -f "$MODULES_FILE"

# Helper: get version by id (linear scan; Bash 3 friendly)
get_version_by_id() {
  local target="$1"
  local i
  for (( i=0; i<${#ALL_IDS[@]}; i++ )); do
    if [[ "${ALL_IDS[$i]}" == "$target" ]]; then
      echo "${ALL_VERS[$i]}"
      return 0
    fi
  done
  echo ""
  return 1
}

# -------- Preflight: app must be explicitly enabled with version --------
app_enabled=0
app_version=""
for id in "${ENABLED_IDS[@]}"; do
  if [[ "$id" == "com.google.firebase.app" ]]; then
    app_enabled=1
    app_version="$(get_version_by_id "com.google.firebase.app")" || true
    break
  fi
done
if [[ $app_enabled -ne 1 ]]; then
  echo "ERROR: com.google.firebase.app must be present in config and enabled=true."
  echo "Fix your config (tools/firebase_tgz.config.jsonc) and re-run."
  exit 1
fi
if [[ -z "$app_version" ]]; then
  echo "ERROR: com.google.firebase.app is enabled but has no version in config."
  exit 1
fi

# Order: app first
ORDERED=("com.google.firebase.app")
for id in "${ENABLED_IDS[@]}"; do
  [[ "$id" != "com.google.firebase.app" ]] && ORDERED+=("$id")
done

download_and_unpack () {
  local id="$1"
  local version
  version="$(get_version_by_id "$id")" || true
  if [[ -z "$version" ]]; then
    echo "ERROR: No version found for $id"
    exit 1
  fi

  local url="${BASE_URL}${id}/${id}-${version}.tgz"
  local dest="$DEST_ROOT/$id"
  local pkgjson="$dest/package.json"

  echo "Resolved URL: $url"

  if [[ $FORCE -eq 0 && -f "$pkgjson" ]]; then
    echo "- $id already installed -> skip (use --force to reinstall)"
    return 0
  fi

  local tmp; tmp="$(mktemp -d)"
  echo "Downloading $id ($version)"
  if ! curl -fL "$url" -o "$tmp/pkg.tgz"; then
    echo "ERROR: Failed to download: $url"
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$dest"; mkdir -p "$dest"
  tar -xzf "$tmp/pkg.tgz" -C "$tmp"
  if [[ -d "$tmp/package" ]]; then
    shopt -s dotglob; mv "$tmp/package/"* "$dest/"; shopt -u dotglob
  else
    shopt -s dotglob; mv "$tmp/"* "$dest/" 2>/dev/null || true; shopt -u dotglob
  fi
  rm -rf "$tmp"
  echo "OK  $id -> $dest"
}

ensure_manifest_dep () {
  local id="$1"
  local value="file:../${DEST_ROOT}/${id}"
  python3 - "$MANIFEST" "$id" "$value" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]); pkg_id = sys.argv[2]; pkg_val = sys.argv[3]
if not p.exists():
    print(f"ERROR: {p} not found. Open the Unity project once to generate it.")
    sys.exit(1)
data = json.loads(p.read_text(encoding='utf-8'))
deps = data.get("dependencies") or {}
if deps.get(pkg_id) != pkg_val:
    deps[pkg_id] = pkg_val
    data["dependencies"] = deps
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    print(f"OK  manifest: {pkg_id} -> {pkg_val}")
else:
    print(f"- manifest already contains {pkg_id}")
PY
}

cleanup_unused () {
  python3 - "$MANIFEST" "$DEST_ROOT" "${ENABLED_IDS[@]}" <<'PY'
import json, sys, pathlib, shutil
p_manifest = pathlib.Path(sys.argv[1])
dest_root  = pathlib.Path(sys.argv[2])
active = set(sys.argv[3:])
if not p_manifest.exists():
    print(f"Skip cleanup: {p_manifest} not found."); sys.exit(0)

data = json.loads(p_manifest.read_text(encoding='utf-8'))
deps = data.get("dependencies") or {}

def is_target(k: str)->bool:
    return k.startswith("com.google.firebase.") or k=="com.google.external-dependency-manager"

removed=[]
for k in list(deps.keys()):
    if is_target(k) and k not in active:
        removed.append(k); deps.pop(k, None)

if removed:
    data["dependencies"]=deps
    p_manifest.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    print("Removed from manifest: " + ", ".join(removed))
    for k in removed:
        d = dest_root / k
        if d.exists():
            shutil.rmtree(d, ignore_errors=True)
            print(f"Removed folder: {d}")
else:
    print("Cleanup: nothing to remove")
PY
}

echo "== Unity Firebase Auto Setup (bash) =="
echo "Config    : $CONFIG_FILE"
echo "Destination: $DEST_ROOT"
echo "Force mode: $FORCE"
if [[ $NO_CLEANUP -eq 0 ]]; then echo "Cleanup   : 1"; else echo "Cleanup   : 0"; fi

# 1) Download/unpack enabled (app first)
for id in "${ORDERED[@]}"; do download_and_unpack "$id"; done

# 2) Ensure manifest deps
for id in "${ORDERED[@]}"; do ensure_manifest_dep "$id"; done

# 3) Cleanup unless skipped
if [[ $NO_CLEANUP -eq 0 ]]; then
  cleanup_unused
else
  echo "Skipping cleanup (flag --no-cleanup)"
fi

echo "== Done =="