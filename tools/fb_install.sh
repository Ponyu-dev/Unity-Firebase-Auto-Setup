#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   bash tools/fb_install.sh [config.jsonc] [--force|-f] [--no-cleanup]
CONFIG_FILE="${1:-Unity-Firebase-Auto-Setup/tools/firebase_tgz.config.jsonc}"
FORCE=0
NO_CLEANUP=0
for arg in "$@"; do
  [[ "$arg" == "--force" || "$arg" == "-f" ]] && FORCE=1
  [[ "$arg" == "--no-cleanup" ]] && NO_CLEANUP=1
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config not found: $CONFIG_FILE"
  echo "Expected at Unity-Firebase-Auto-Setup/tools/firebase_tgz.config.jsonc (or pass path as 1st arg)."
  exit 1
fi

MODULES_FILE="$(mktemp)"

# ВАЖНО: eval выполняем в текущем шелле, а печать списка модулей — в файл
{
  eval "$(python3 - <<'PY' "$CONFIG_FILE"
import sys, json, re, pathlib
p = pathlib.Path(sys.argv[1])
txt = p.read_text(encoding='utf-8')
txt = re.sub(r'^\s*//.*$', '', txt, flags=re.M)
cfg = json.loads(txt)

print(f'BASE_URL="{cfg["base_url"].rstrip("/")}/"')
print(f'DEST_ROOT="{cfg["dest_root"]}"')
print(f'MANIFEST="{cfg["manifest"]}"')

print("MODULES_START")
for m in cfg.get("modules", []):
    mid = m["id"].replace(" ", "")
    ver = (m.get("version") or "").strip()
    en  = "true" if bool(m.get("enabled")) else "false"
    print(f'MODULE {mid} {ver} {en}')
print("MODULES_END")
PY
)"
} > "$MODULES_FILE"

# Проверим, что переменные заданы
: "${BASE_URL:?BASE_URL not set}"
: "${DEST_ROOT:?DEST_ROOT not set}"
: "${MANIFEST:?MANIFEST not set}"

mkdir -p "$DEST_ROOT"

# Разобрать MODULES_FILE
ENABLED_IDS=()
declare -A VER
in_block=0
while IFS= read -r line; do
  [[ "$line" == "MODULES_START" ]] && { in_block=1; continue; }
  [[ "$line" == "MODULES_END"   ]] && { in_block=0; continue; }
  [[ $in_block -eq 0 ]] && continue

  # format: MODULE <id> <version> <enabled>
  read -r tag id ver enabled <<<"$line"
  [[ "$tag" != "MODULE" ]] && continue
  VER["$id"]="$ver"
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

# Порядок: app первой
ORDERED=()
has_app=0
for id in "${ENABLED_IDS[@]}"; do
  [[ "$id" == "com.google.firebase.app" ]] && has_app=1
done
if [[ $has_app -eq 0 ]]; then ORDERED+=("com.google.firebase.app"); fi
for id in "${ENABLED_IDS[@]}"; do
  [[ "$id" != "com.google.firebase.app" ]] && ORDERED+=("$id")
done

download_and_unpack () {
  local id="$1"
  local version="${VER[$id]}"
  local url="${BASE_URL}${id}/${id}-${version}.tgz"
  local dest="$DEST_ROOT/$id"
  local pkgjson="$dest/package.json"

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
  # Удалить пакеты, которые не включены в конфиг (из manifest и из DEST_ROOT)
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
echo "Dest    = $DEST_ROOT"
echo "Force   = $FORCE"
echo "Cleanup = $((NO_CLEANUP==0?1:0))"

# 1) Download/unpack enabled
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