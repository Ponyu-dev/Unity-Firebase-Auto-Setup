#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   bash tools/fb_install.sh [config.jsonc] [--force|-f] [--no-cleanup]
CONFIG_FILE="${1:-tools/firebase_tgz.config.jsonc}"
FORCE=0
NO_CLEANUP=0
for arg in "$@"; do
  [[ "$arg" == "--force" || "$arg" == "-f" ]] && FORCE=1
  [[ "$arg" == "--no-cleanup" ]] && NO_CLEANUP=1
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config not found: $CONFIG_FILE"
  echo "Expected at tools/firebase_tgz.config.jsonc (or pass path as 1st arg)."
  exit 1
fi

# Read JSONC -> emit env + a plain table: "MODULE <id> <version> <enabled>"
eval "$(python3 - <<'PY' "$CONFIG_FILE"
import sys, json, re, pathlib
p = pathlib.Path(sys.argv[1])
txt = p.read_text(encoding='utf-8')
txt = re.sub(r'^\s*//.*$', '', txt, flags=re.M)
cfg = json.loads(txt)

print(f'BASE_URL="{cfg["base_url"].rstrip("/")}/"')
print(f'DEST_ROOT="{cfg["dest_root"]}"')
print(f'MANIFEST="{cfg["manifest"]}"')
print("echo MODULES_START")
for m in cfg.get("modules", []):
    mid = m["id"]; ver = m.get("version") or ""
    en  = "true" if bool(m.get("enabled")) else "false"
    mid = mid.replace(" ", "")
    print(f'echo MODULE {mid} {ver} {en}')
print("echo MODULES_END")
PY
)" | awk '
  BEGIN{out=0}
  /MODULES_START/{out=1; next}
  /MODULES_END/{out=0; next}
  { if(out) print > "/tmp/fbmods.txt"; else print }
'

mkdir -p "$DEST_ROOT"

# read modules table
mapfile -t LINES < /tmp/fbmods.txt
ENABLED_IDS=()
ALL_IDS=()
declare -A VER
for line in "${LINES[@]}"; do
  read -r _ id ver enabled <<<"$line"
  ALL_IDS+=("$id")
  VER["$id"]="$ver"
  if [[ "$enabled" == "true" ]]; then
    if [[ -z "$ver" ]]; then
      echo "✗ Version is required for enabled module: $id"; exit 1
    fi
    ENABLED_IDS+=("$id")
  fi
done

ORDERED=()
has_app=0
for id in "${ENABLED_IDS[@]}"; do [[ "$id" == "com.google.firebase.app" ]] && has_app=1; done
if [[ $has_app -eq 0 ]]; then ORDERED+=("com.google.firebase.app"); fi
for id in "${ENABLED_IDS[@]}"; do [[ "$id" != "com.google.firebase.app" ]] && ORDERED+=("$id"); done

download_and_unpack () {
  local id="$1"; local version="${VER[$id]}"
  local url="${BASE_URL}${id}/${id}-${version}.tgz"
  local dest="$DEST_ROOT/$id"
  local pkgjson="$dest/package.json"

  if [[ $FORCE -eq 0 && -f "$pkgjson" ]]; then
    echo "• $id already installed → skip (use --force to reinstall)"; return 0
  fi

  local tmp; tmp="$(mktemp -d)"
  echo "⇣ Download $id ($version)"
  if ! curl -fL "$url" -o "$tmp/pkg.tgz"; then
    echo "✗ Failed to download: $url"; rm -rf "$tmp"; exit 1
  fi

  rm -rf "$dest"; mkdir -p "$dest"
  tar -xzf "$tmp/pkg.tgz" -C "$tmp"
  if [[ -d "$tmp/package" ]]; then
    shopt -s dotglob; mv "$tmp/package/"* "$dest/"; shopt -u dotglob
  else
    shopt -s dotglob; mv "$tmp/"* "$dest/" || true; shopt -u dotglob
  fi
  rm -rf "$tmp"
  echo "✓ $id → $dest"
}

ensure_manifest_dep () {
  local id="$1"
  local value="file:../${DEST_ROOT}/${id}"
  python3 - "$MANIFEST" "$id" "$value" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]); pkg_id = sys.argv[2]; pkg_val = sys.argv[3]
if not p.exists():
    print(f"✗ {p} not found. Open the Unity project once to let it generate.")
    sys.exit(1)
data = json.loads(p.read_text(encoding='utf-8'))
deps = data.get("dependencies") or {}
if deps.get(pkg_id) != pkg_val:
    deps[pkg_id] = pkg_val
    data["dependencies"] = deps
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    print(f"✓ manifest.json: {pkg_id} → {pkg_val}")
else:
    print(f"• manifest.json already contains {pkg_id}")
PY
}

cleanup_unused () {
  python3 - "$MANIFEST" "$DEST_ROOT" "${ENABLED_IDS[@]}" <<'PY'
import json, sys, pathlib
p_manifest = pathlib.Path(sys.argv[1])
dest_root = pathlib.Path(sys.argv[2])
active = set(sys.argv[3:])
if not p_manifest.exists():
    print(f"✗ {p_manifest} not found; skip cleanup."); sys.exit(0)

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
    print("🧹 Removed from manifest:", ", ".join(removed))
    import shutil
    for k in removed:
        d = dest_root / k
        if d.exists():
            shutil.rmtree(d, ignore_errors=True)
            print(f"🧹 Removed folder: {d}")
else:
    print("• Cleanup: nothing to remove")
PY
}

echo "== Unity Firebase Auto Setup (bash) =="
echo "Dest: $DEST_ROOT"
echo "Enabled: ${#ENABLED_IDS[@]}   Force: $FORCE   Cleanup: $((NO_CLEANUP==0?1:0))"

for id in "${ORDERED[@]}"; do download_and_unpack "$id"; done
for id in "${ORDERED[@]}"; do ensure_manifest_dep "$id"; done
if [[ $NO_CLEANUP -eq 0 ]]; then cleanup_unused; else echo "⚠️  Skipping cleanup (by flag)"; fi

echo "== Done =="