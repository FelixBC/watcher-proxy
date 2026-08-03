#!/usr/bin/env bash
# build-winconfig-bundle.sh — packages this repo into the self-contained
# "WinConfig" install zip used BOTH for the manual Drive upload and as what
# install.ps1 (the hosted bootstrapper) downloads. Run on macOS (Felix's
# machine) — uses only macOS/BSD built-ins (zip, unzip, shasum, stat), no npm
# dependency, mirroring how scripts/publish-agent.mjs (in the sibling
# watcher-fleet repo) packages the OTA self-update patch — but this is a
# DIFFERENT artifact: a full fresh-install bundle wrapped in a WinConfig/ top
# folder (incl. a default whitelist.txt), not an in-place code patch.
#
# Usage:
#   scripts/build-winconfig-bundle.sh [--dir <path-to-watcher-proxy>] [--out <dist-dir>]
#
# Output:
#   <out>/winconfig-install-v<VERSION>.zip   (archival, versioned — e.g. for Drive)
#   <out>/winconfig-install.zip              (stable name — what install.ps1's
#                                              $BundleUrl placeholder points at)
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-winconfig-bundle.sh [--dir <path-to-watcher-proxy>] [--out <dist-dir>]

  --dir   Path to the watcher-proxy repo to package (default: this script's repo).
  --out   Output directory for the zip(s) (default: <repo>/dist).
EOF
}

DIR_ARG=""
OUT_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir) DIR_ARG="$2"; shift 2 ;;
        --out) OUT_ARG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${DIR_ARG:-$(cd "$SCRIPT_DIR/.." && pwd)}"
OUT_DIR="${OUT_ARG:-$REPO_ROOT/dist}"

cd "$REPO_ROOT"

if [[ ! -f VERSION ]]; then
    echo "ERROR: no VERSION file in $REPO_ROOT — wrong --dir?" >&2
    exit 1
fi
VERSION="$(tr -d '[:space:]' < VERSION)"

if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: $REPO_ROOT is not a git repo." >&2
    echo "       This script relies on git to tell tracked/safe files apart from" >&2
    echo "       gitignored secrets and per-machine state — it refuses to guess." >&2
    exit 1
fi

echo "Packaging WinConfig agent v$VERSION from $REPO_ROOT ..."

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
WINCONFIG_DIR="$STAGE/WinConfig"
mkdir -p "$WINCONFIG_DIR"

# ------------------------------------------------------------------------------
# Base file set = everything git considers NOT secret / NOT machine state:
# tracked files, PLUS untracked files that are not gitignored. That second half
# matters here specifically: other propose-only subtasks on this branch add
# new files (e.g. WatcherBrain/agent-code-crypto.js) without ever `git add`-ing
# them, so plain `git ls-files` alone would silently drop them. Anything
# .gitignore already marks as secret/per-machine (HubConfig.json,
# hub-credential.json, master-code.plain, uninstall-code.hash, machine-*.txt,
# whitelist-version.txt, *.log, *.zip, node/, _backup_*, updating.flag,
# unplugged.flag, ...) is untracked AND ignored, so it never appears either
# way. This is the actual EXCLUDE mechanism, driven by .gitignore instead of a
# hand-duplicated list that could drift from it.
# ------------------------------------------------------------------------------
FILES=()
while IFS= read -r f; do
    FILES+=("$f")
done < <(git -C "$REPO_ROOT" ls-files --cached --others --exclude-standard)

# On top of the git-safe set, drop paths that are tracked but are NOT agent
# payload:
#   - this packaging script and install.ps1 itself (delivery tooling, not
#     something that belongs inside the installed folder)
#   - .gitignore (dev meta)
#   - README.txt / ARCHITECTURE.md / docs/ — DECISION (not in the original
#     ask, flagged in the handoff report): these are dev-facing and/or
#     literally banner "WATCHER" in their text. Shipping them at the TOP of
#     the disguised WinConfig folder would hand a banca worker who opens it
#     exactly the explanation AC3 is trying to keep from them. None of them
#     are read by any install/runtime script (grep the repo — nothing
#     references README.txt or ARCHITECTURE.md except InstallWatcher.bat's
#     own end-of-run console text, which just prints slightly stale advice
#     if this file is absent; harmless).
EXCLUDE_PATHS=(
    ".gitignore"
    "install.ps1"
    "scripts/build-winconfig-bundle.sh"
    "scripts/installer"
    # CI-only: the headless install reproduction + its GitHub Actions workflow. Pure
    # dev tooling (drives InstallWatcher.bat on a Windows runner), never read by any
    # install/runtime script - so it must not land in the disguised WinConfig folder.
    "scripts/ci"
    ".github"
    # Local dev tooling only. `.claude` holds Claude Code's config AND its git
    # worktrees (.claude/worktrees/<name>) — nested working trees git lists as
    # untracked entries. Packaging them tries to cp a whole worktree into the
    # bundle (fatal: "cp: .../installer-visual: No such file or directory") and
    # would ship the repo twice besides. Never agent payload — exclude the lot.
    ".claude"
    "README.txt"
    "ARCHITECTURE.md"
    "docs"
    # Instalar.bat predates Instalar.exe (v1.0.19, same behaviour, carries the gear
    # icon in Explorer). Both were shipping side by side with nothing telling a
    # banca worker which to use - confirmed source of "2 instalar, no se cual usar"
    # confusion. Instalar.exe is now the ONE launcher on the machine; Instalar.bat
    # stays in the repo (git-tracked) as a manual dev fallback only, not packaged.
    "Instalar.bat"
)

is_excluded() {
    local f="$1" x
    for x in "${EXCLUDE_PATHS[@]}"; do
        if [[ "$f" == "$x" || "$f" == "$x"/* ]]; then
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------------------------
# Windows-hostile filename guard. The exclude mechanism above is ALLOW-by-default
# (tracked + not-gitignored), and .gitignore is extension/path-shaped — so a stray
# file whose NAME is the problem sails straight through it. Real case: an accidental
# `$LOG` in the repo root (a shell redirect whose variable never expanded). `*.log`
# does not match `$LOG`, `git check-ignore` does not ignore it, and the *.log
# self-check further down never sees it either — so it shipped inside the bundle.
#
# Two families are refused, both fatal for a Windows payload:
#   1. INVALID on Win32 — the zip cannot even extract cleanly: <>:"|?*\ , control
#      characters, reserved device names (CON/PRN/AUX/NUL/COM#/LPT#), and a segment
#      with a trailing dot or space.
#   2. DANGEROUS — legal on NTFS, but a metacharacter in the cmd/PowerShell scripts
#      that ARE this agent: a segment starting with `$` (PowerShell variable), or
#      containing `%` (cmd variable), a backtick (PowerShell escape), `!` (cmd
#      delayed expansion — InstallWatcher.bat and CleanPrintSpoolOncePerDay.bat both
#      `setlocal enabledelayedexpansion`), or `&` (cmd command separator).
#
# Deliberately scoped to the git-derived set and applied AFTER is_excluded, not over
# the whole stage: a stray is a working-tree accident, whereas WatcherBrain/node/ is
# a downloaded Node distribution whose file names this guard must never get to veto
# (it would block a release over something we don't own).
#
# The SAME rule guards the OTA path in watcher-fleet/scripts/publish-agent.mjs (there
# it runs over the built zip's entry list). Keep the two rule sets in step.
# ------------------------------------------------------------------------------
windows_hostile_reason() {
    # Prints a reason and returns 0 when the path is unsafe for a Windows payload.
    # Splits on "/" with parameter expansion, never word splitting: `for seg in $path`
    # would pathname-expand the very `*`/`?` characters this is looking for.
    local rest="$1" seg base upper
    while [[ -n "$rest" ]]; do
        seg="${rest%%/*}"
        if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
        [[ -z "$seg" ]] && continue

        case "$seg" in
            *'<'*|*'>'*|*':'*|*'"'*|*'|'*|*'?'*|*'*'*|*'\'*)
                echo "illegal Windows character"; return 0 ;;
        esac
        if [[ "$seg" =~ [[:cntrl:]] ]]; then
            echo "control character"; return 0
        fi
        case "$seg" in
            *. | *' ')
                echo "trailing dot or space"; return 0 ;;
        esac
        base="${seg%%.*}"
        upper="$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')"   # bash 3.2: no ${x^^}
        case "$upper" in
            # Win32 also treats the superscript digits ¹²³ as device numbers (COM¹ ≡ COM1).
            # Spelled out instead of a [0-9¹²³] bracket expression: bash 3.2 bracket matching
            # over multibyte characters is locale-dependent and not reliable here.
            CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9]|COM¹|COM²|COM³|LPT¹|LPT²|LPT³)
                echo "reserved Windows device name"; return 0 ;;
        esac
        case "$seg" in
            '$'*)  echo "starts with '\$' (PowerShell variable)"; return 0 ;;
            *'%'*) echo "contains '%' (cmd variable)"; return 0 ;;
            *'`'*) echo "contains a backtick (PowerShell escape)"; return 0 ;;
            *'!'*) echo "contains '!' (cmd delayed expansion)"; return 0 ;;
            *'&'*) echo "contains '&' (cmd command separator)"; return 0 ;;
            # `^` is the cmd escape character. Kept in step with the OTA guard in
            # publish-agent.mjs, where it does double duty: `unzip -Z1` renders a control
            # character in caret notation, so rejecting `^` is what keeps that guard's
            # control-character rule reachable. Here git quotes such a path instead
            # (it lists as "tab\tname.js"), which the illegal-character rule already
            # catches — but the two rule sets stay identical on purpose.
            *'^'*) echo "contains '^' (cmd escape / escaped control character)"; return 0 ;;
        esac
    done
    return 1
}

hostile=0
for f in "${FILES[@]}"; do
    if is_excluded "$f"; then
        continue
    fi
    if reason="$(windows_hostile_reason "$f")"; then
        echo "ERROR: refusing to package '$f' — $reason." >&2
        hostile=$((hostile + 1))
    fi
done
if [[ $hostile -gt 0 ]]; then
    echo "" >&2
    echo "$hostile file name(s) above are invalid or unsafe on Windows — aborting, nothing written." >&2
    echo "These are almost certainly stray files (e.g. a shell redirect that never expanded)." >&2
    echo "Delete them from $REPO_ROOT, or add them to .gitignore, then re-run." >&2
    exit 1
fi

copied=0
for f in "${FILES[@]}"; do
    if is_excluded "$f"; then
        continue
    fi
    mkdir -p "$WINCONFIG_DIR/$(dirname "$f")"
    cp "$REPO_ROOT/$f" "$WINCONFIG_DIR/$f"
    copied=$((copied + 1))
done
echo "  copied $copied files (git-tracked + untracked-but-not-gitignored, minus delivery/dev-doc exclusions)"

# ------------------------------------------------------------------------------
# Bundled Node (offline capability). WatcherBrain/node/ is gitignored (a large
# binary, never committed), so it never appears in the set above — copy it in
# explicitly when present on this machine (WatcherBrain/DownloadNode.ps1's
# target). If it's absent, the bundle is still valid (AC6: the ONLINE install
# path downloads Node itself via DownloadNode.ps1) — just not offline-capable,
# so warn loudly instead of failing.
# ------------------------------------------------------------------------------
NODE_BUNDLED="no"
if [[ -f "$REPO_ROOT/WatcherBrain/node/node.exe" ]]; then
    mkdir -p "$WINCONFIG_DIR/WatcherBrain/node"
    cp -R "$REPO_ROOT/WatcherBrain/node/." "$WINCONFIG_DIR/WatcherBrain/node/"
    NODE_BUNDLED="yes"
    echo "  bundled Node found (WatcherBrain/node/node.exe) — offline-capable bundle"
else
    echo ""
    echo "WARNING: WatcherBrain/node/node.exe not found in $REPO_ROOT."
    echo "         This zip will be ONLINE-ONLY: a machine with no internet and no"
    echo "         system Node.js cannot self-install (InstallWatcher.bat falls back"
    echo "         to WatcherBrain/DownloadNode.ps1, which itself needs internet)."
    echo "         For a true offline/self-contained bundle, populate"
    echo "         WatcherBrain/node/ (run WatcherBrain/DownloadNode.ps1 once) before"
    echo "         packaging."
    echo ""
fi

# ------------------------------------------------------------------------------
# Clean HubConfig.json: ONLY HubUrl, no secret — regenerated fresh rather than
# copied, because the real WatcherBrain/HubConfig.json on disk (gitignored,
# per-machine) may still carry the retired EnrollmentSecret field from before
# the master-code rework. The master code is prompted at install time
# (AskIdentity.ps1) and is never baked into the package. HubUrl is pulled from
# HubConfig.example.json when present, else falls back to the placeholder below.
# ------------------------------------------------------------------------------
HUB_URL_PLACEHOLDER="https://watcher-fleet.vercel.app"   # fallback only
HUB_URL="$HUB_URL_PLACEHOLDER"
EXAMPLE="$REPO_ROOT/WatcherBrain/HubConfig.example.json"
if [[ -f "$EXAMPLE" ]]; then
    extracted="$(grep -o '"HubUrl"[[:space:]]*:[[:space:]]*"[^"]*"' "$EXAMPLE" | sed -E 's/.*"HubUrl"[[:space:]]*:[[:space:]]*"([^"]*)"/\1/' || true)"
    if [[ -n "$extracted" ]]; then
        HUB_URL="$extracted"
    fi
fi
mkdir -p "$WINCONFIG_DIR/WatcherBrain"
cat > "$WINCONFIG_DIR/WatcherBrain/HubConfig.json" <<EOF
{
  "HubUrl": "$HUB_URL"
}
EOF
echo "  wrote WatcherBrain/HubConfig.json (HubUrl only, no secret): $HUB_URL"

# ------------------------------------------------------------------------------
# Defensive self-check: refuse to produce a zip if anything secret/machine-
# state-shaped slipped into the stage, or if the retired EnrollmentSecret
# field somehow ended up in the regenerated HubConfig.json. This is a PUBLIC
# bundle (Supabase public storage / Drive) — never publish these.
# ------------------------------------------------------------------------------
for bad in \
    "WatcherBrain/hub-credential.json" \
    "master-code.plain" \
    "uninstall-code.hash" \
    "machine-name.txt" "machine-zone.txt" "machine-code.txt" \
    "WatcherBrain/whitelist-version.txt" \
    "WatcherBrain/updating.flag" "WatcherBrain/unplugged.flag" \
    "WatcherBrain/update-failed.json" \
    "WatcherBrain/staging.flag" "WatcherBrain/selftest-state.json" "WatcherBrain/selftest.lock" \
    "WatcherBrain/register-status.txt"; do
    if [[ -e "$WINCONFIG_DIR/$bad" ]]; then
        echo "ERROR: secret/machine-state file '$bad' ended up in the stage — aborting, nothing written." >&2
        exit 1
    fi
done
if find "$WINCONFIG_DIR" -name '*.log' -print -quit | grep -q .; then
    echo "ERROR: a *.log file ended up in the stage — aborting, nothing written." >&2
    exit 1
fi
if grep -q "EnrollmentSecret" "$WINCONFIG_DIR/WatcherBrain/HubConfig.json"; then
    echo "ERROR: EnrollmentSecret leaked into the packaged HubConfig.json — aborting." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Zip it. Top-level folder MUST be exactly "WinConfig" — the bootstrapper
# (install.ps1) extracts straight to C:\WinConfig and expects
# WinConfig\InstallWatcher.bat, WinConfig\WatcherBrain\... at that path.
# ------------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
VERSIONED_ZIP="$OUT_DIR/winconfig-install-v${VERSION}.zip"
STABLE_ZIP="$OUT_DIR/winconfig-install.zip"
rm -f "$VERSIONED_ZIP"

( cd "$STAGE" && zip -r -q -X "$VERSIONED_ZIP" WinConfig -x '*.DS_Store' )
cp -f "$VERSIONED_ZIP" "$STABLE_ZIP"

top_entry="$(unzip -Z1 "$VERSIONED_ZIP" | head -1)"
if [[ "$top_entry" != WinConfig/* ]]; then
    echo "ERROR: zip top-level entry is '$top_entry', not 'WinConfig/' — aborting, nothing published." >&2
    rm -f "$VERSIONED_ZIP" "$STABLE_ZIP"
    exit 1
fi

# ------------------------------------------------------------------------------
# Report — mirrors watcher-fleet/scripts/publish-agent.mjs's style (size + sha256).
# ------------------------------------------------------------------------------
size_bytes=$(stat -f%z "$VERSIONED_ZIP" 2>/dev/null || stat -c%s "$VERSIONED_ZIP")
size_kb=$(( (size_bytes + 1023) / 1024 ))
sha256=$(shasum -a 256 "$VERSIONED_ZIP" | awk '{print $1}')

echo ""
echo "Built:  $VERSIONED_ZIP"
echo "Copied: $STABLE_ZIP  (stable name — what install.ps1's \$BundleUrl downloads)"
echo "  size:         ${size_kb} KB (${size_bytes} bytes)"
echo "  sha256:       ${sha256}"
echo "  node bundled: ${NODE_BUNDLED}"
echo ""
echo "Next: upload $STABLE_ZIP to wherever install.ps1's \$BundleUrl points (e.g. the"
echo "Supabase agent-releases public bucket) and/or to Drive for the offline copy."
