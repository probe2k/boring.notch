#!/usr/bin/env bash
#
# cleanup.sh — wipe local Xcode build artifacts for boringNotch.
#
# What this does:
#   1. xcodebuild clean (Debug + Release) for the boringNotch scheme.
#   2. Unregister any locally-built boringNotch.app from LaunchServices so
#      Spotlight stops surfacing the DerivedData copy.
#   3. Delete the project's DerivedData folder under
#      ~/Library/Developer/Xcode/DerivedData/boringNotch-*.
#   4. Delete only this project's *.xcarchive files under
#      ~/Library/Developer/Xcode/Archives, and prune any day-folders that
#      become empty as a result. Other projects' archives are left alone.
#   5. Print a verification report.
#
# What this deliberately does NOT touch:
#   - Anything inside /Applications.
#   - Anything on the Desktop (TestFlight exports, etc.).
#   - The project source tree.
#   - User defaults, sandbox containers, or TCC permissions for the app
#     (use a separate reset flow if you want a true fresh-install state).
#
# Usage:
#   scripts/cleanup.sh                # default: clean + unregister + delete
#   scripts/cleanup.sh --keep-archives  # leave xcarchives alone
#   scripts/cleanup.sh --dry-run        # print what would happen, change nothing
#   scripts/cleanup.sh -h | --help      # show help
#
# Safe to run when nothing has been built yet — each step skips itself if
# its target doesn't exist. Exits 0 on success, non-zero only on
# unrecoverable errors (e.g. xcodebuild crash).

set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Resolve project root (the directory containing the .xcodeproj). Works
# regardless of where the script is invoked from.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XCODEPROJ_NAME="boringNotch.xcodeproj"
SCHEME="boringNotch"

if [[ ! -d "$PROJECT_ROOT/$XCODEPROJ_NAME" ]]; then
    echo "error: cannot find $XCODEPROJ_NAME at $PROJECT_ROOT" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
KEEP_ARCHIVES=0
DRY_RUN=0

while (( $# > 0 )); do
    case "$1" in
        --keep-archives)  KEEP_ARCHIVES=1 ;;
        --dry-run|-n)     DRY_RUN=1 ;;
        -h|--help)
            sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,31p'
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            echo "       try $0 --help" >&2
            exit 1
            ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
section() { printf '\n\033[1;34m== %s ==\033[0m\n' "$1"; }
ok()      { printf '  \033[32m✓\033[0m %s\n' "$1"; }
info()    { printf '  • %s\n' "$1"; }
warn()    { printf '  \033[33m!\033[0m %s\n' "$1"; }
run()     {
    if (( DRY_RUN )); then
        printf '  \033[36m[dry-run]\033[0m %s\n' "$*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Step 1 — xcodebuild clean
# ---------------------------------------------------------------------------
section "xcodebuild clean (Debug + Release)"
if ! command -v xcodebuild >/dev/null 2>&1; then
    warn "xcodebuild not found in PATH — skipping clean step"
else
    for cfg in Debug Release; do
        if (( DRY_RUN )); then
            info "[dry-run] xcodebuild clean -configuration $cfg"
        else
            if ( cd "$PROJECT_ROOT" && \
                 xcodebuild -project "$XCODEPROJ_NAME" \
                            -scheme "$SCHEME" \
                            -configuration "$cfg" \
                            clean >/dev/null 2>&1 ); then
                ok "$cfg clean succeeded"
            else
                warn "$cfg clean failed or scheme not buildable — continuing"
            fi
        fi
    done
fi

# ---------------------------------------------------------------------------
# Step 2 — Unregister any built copy from LaunchServices
# ---------------------------------------------------------------------------
section "Unregister built copies from LaunchServices"
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ ! -x "$LSREG" ]]; then
    warn "lsregister not found — skipping"
else
    found_any=0
    # Glob handles users with multiple DerivedData entries (rare but possible).
    shopt -s nullglob
    for dd in "$HOME/Library/Developer/Xcode/DerivedData/boringNotch-"*; do
        for cfg in Debug Release; do
            app="$dd/Build/Products/$cfg/boringNotch.app"
            if [[ -d "$app" ]]; then
                found_any=1
                if (( DRY_RUN )); then
                    info "[dry-run] lsregister -u $app"
                else
                    "$LSREG" -u "$app" >/dev/null 2>&1 \
                        && ok "unregistered $cfg copy in $(basename "$dd")"
                fi
            fi
        done
    done
    shopt -u nullglob
    (( found_any )) || info "no built boringNotch.app to unregister"
fi

# ---------------------------------------------------------------------------
# Step 3 — Delete DerivedData for this project only
# ---------------------------------------------------------------------------
section "Delete DerivedData"
shopt -s nullglob
dd_entries=("$HOME/Library/Developer/Xcode/DerivedData/boringNotch-"*)
shopt -u nullglob
if (( ${#dd_entries[@]} == 0 )); then
    info "no boringNotch DerivedData to delete"
else
    for dd in "${dd_entries[@]}"; do
        size="$(du -sh "$dd" 2>/dev/null | awk '{print $1}')"
        run rm -rf "$dd"
        (( DRY_RUN )) || ok "removed $(basename "$dd") ($size)"
    done
fi

# ---------------------------------------------------------------------------
# Step 4 — Delete only this project's xcarchives, prune empty day-folders
# ---------------------------------------------------------------------------
if (( KEEP_ARCHIVES )); then
    section "Archives"
    info "skipped (--keep-archives)"
else
    section "Delete project xcarchives"
    archives_root="$HOME/Library/Developer/Xcode/Archives"
    if [[ ! -d "$archives_root" ]]; then
        info "no Archives directory"
    else
        removed_count=0
        # Match xcarchives that belong to this project, by name. The
        # archive name pattern Xcode generates is "<scheme> <timestamp>.xcarchive";
        # we match both boringNotch and BoringNotchXPCHelper.
        while IFS= read -r -d '' arch; do
            run rm -rf "$arch"
            (( DRY_RUN )) || removed_count=$((removed_count + 1))
        done < <(find "$archives_root" -type d \
                      \( -iname 'boringNotch *.xcarchive' \
                      -o -iname 'BoringNotchXPCHelper *.xcarchive' \) \
                      -prune -print0 2>/dev/null)

        if (( DRY_RUN )); then
            info "[dry-run] would also prune any day-folders left empty"
        else
            (( removed_count > 0 )) \
                && ok "removed $removed_count xcarchive(s)" \
                || info "no project xcarchives to remove"

            # Prune now-empty YYYY-MM-DD day folders (won't touch folders
            # that still contain another project's archives).
            pruned=0
            while IFS= read -r -d '' day; do
                if rmdir "$day" 2>/dev/null; then
                    pruned=$((pruned + 1))
                fi
            done < <(find "$archives_root" -mindepth 1 -maxdepth 1 -type d \
                          -name '20[0-9][0-9]-[0-1][0-9]-[0-3][0-9]' -print0 2>/dev/null)
            (( pruned > 0 )) && ok "pruned $pruned empty day-folder(s)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Step 5 — Verification
# ---------------------------------------------------------------------------
section "Verification"

# DerivedData
shopt -s nullglob
remaining=("$HOME/Library/Developer/Xcode/DerivedData/boringNotch-"*)
shopt -u nullglob
if (( ${#remaining[@]} == 0 )); then
    ok "DerivedData: no boringNotch entries"
else
    # Some IDE integrations (Cursor, SourceKit-LSP, project-watching
    # tools) re-create an empty DerivedData scaffold immediately. That's
    # harmless — it contains no build products.
    for dd in "${remaining[@]}"; do
        if find "$dd" -name '*.app' -maxdepth 5 -print -quit 2>/dev/null | read -r; then
            warn "DerivedData re-appeared with build products: $(basename "$dd")"
        else
            info "DerivedData re-scaffolded by another tool (no build products): $(basename "$dd")"
        fi
    done
fi

# Archives
if [[ -d "$HOME/Library/Developer/Xcode/Archives" ]]; then
    leftover=$(find "$HOME/Library/Developer/Xcode/Archives" -type d \
                    \( -iname 'boringNotch *.xcarchive' \
                    -o -iname 'BoringNotchXPCHelper *.xcarchive' \) \
                    -prune 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$leftover" == "0" ]]; then
        ok "Archives: no project xcarchives"
    else
        warn "Archives: $leftover project xcarchive(s) still present"
    fi
fi

# /Applications
if ls /Applications 2>/dev/null | grep -qi 'boring.*notch'; then
    info "/Applications: installed copy present (untouched)"
else
    ok "/Applications: no installed copy"
fi

# Source tree
if [[ -d "$PROJECT_ROOT/$XCODEPROJ_NAME" ]]; then
    ok "Source tree intact at $PROJECT_ROOT"
fi

printf '\n\033[1;32mCleanup complete.\033[0m\n'
