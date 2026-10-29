#!/usr/bin/env bash
# Big Squirrel OS - setup script (v0.2)
# Just run it:  bash big-squirrel-setup.sh
# Optional:     bash big-squirrel-setup.sh /path/to/acorn.svg
#
# Does:
#   1. Global theme -> CachyOS Nord
#   2. App launcher icon -> acorn
#   3. Taskbar: remove spacers, system tray and clock; auto-hide it
#      Add an auto-hiding top panel
#      Both panels: fit-to-content width, centered, floating
#      Top panel contents: trash, digital clock, volume
#   4. Wallpaper -> image named wallpaper.* in the same folder as this script

log()  { printf '\e[1;33m[big-squirrel]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;31m[big-squirrel]\e[0m %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
KWRITE="$(command -v kwriteconfig6 || command -v kwriteconfig5)"

[[ $EUID -eq 0 ]] && { warn "Run this as your normal user, not root."; exit 1; }

# ---------------- 1. THEME ----------------
log "Step 1/4: global theme"
# Theme IDs and display names differ, so look at the display names inside each theme folder
THEME_ID=""
for dir in "$HOME/.local/share/plasma/look-and-feel" /usr/share/plasma/look-and-feel; do
    [[ -d "$dir" ]] || continue
    for t in "$dir"/*/; do
        id="$(basename "$t")"
        if grep -qis 'nord' "$t"metadata.json "$t"metadata.desktop 2>/dev/null || [[ "${id,,}" == *nord* ]]; then
            # prefer one that also says cachy
            if [[ "${id,,}" == *cachy* ]] || grep -qis 'cachy' "$t"metadata.json "$t"metadata.desktop 2>/dev/null; then
                THEME_ID="$id"; break 2
            fi
            [[ -z "$THEME_ID" ]] && THEME_ID="$id"
        fi
    done
done
if [[ -z "$THEME_ID" ]]; then
    warn "Couldn't find CachyOS Nord. Themes installed on this system:"
    plasma-apply-lookandfeel --list
else
    log "Applying theme: $THEME_ID"
    # --resetLayout also restores the theme's own panel layout and wallpaper (the full "stock" look)
    if plasma-apply-lookandfeel --apply "$THEME_ID" --resetLayout; then
        log "Theme applied (with layout reset)."
    else
        warn "plasma-apply-lookandfeel failed, trying lookandfeeltool..."
        lookandfeeltool -a "$THEME_ID" && log "Theme applied (fallback)."
    fi
    log "Waiting for Plasma to finish loading the theme..."
    sleep 8
fi

# ---------------- 2. ACORN ICON ----------------
log "Step 2/4: app launcher icon"

# Find the acorn file: argument, script folder, then common places
ACORN="${1:-}"
if [[ -z "$ACORN" ]]; then
    ACORN="$(find "$SCRIPT_DIR" "$HOME/Downloads" "$HOME/Pictures" "$HOME/Desktop" "$HOME/Documents" "$HOME/.local/share/icons" "$HOME" \
        -maxdepth 4 -type f -iname 'acorn*' \( -iname '*.svg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.jpg' \) \
        2>/dev/null | head -n1)"
fi

if [[ -n "$ACORN" ]]; then
    log "Found acorn: $ACORN"
    # Copy it somewhere permanent and use the full path as the icon
    mkdir -p "$HOME/.local/share/big-squirrel"
    ext="${ACORN##*.}"
    cp "$ACORN" "$HOME/.local/share/big-squirrel/acorn.$ext"
    ICON_VALUE="$HOME/.local/share/big-squirrel/acorn.$ext"
elif find /usr/share/icons "$HOME/.local/share/icons" -iname 'acorn.*' 2>/dev/null | grep -q .; then
    log "Found 'acorn' in the icon theme."
    ICON_VALUE="acorn"
else
    warn "Can't find an acorn icon. Run:  bash $0 /full/path/to/your/acorn.svg"
    exit 1
fi

# Find every launcher widget (kickoff / kicker / kickerdash) in the Plasma config
PAIRS="$(python3 - "$RC" << 'PY'
import re, sys
cur, out = None, []
for line in open(sys.argv[1], encoding="utf-8", errors="ignore"):
    line = line.strip()
    m = re.fullmatch(r"\[Containments\]\[(\d+)\]\[Applets\]\[(\d+)\]", line)
    if m: cur = m.groups(); continue
    if line.startswith("[") : 
        if not line.startswith("[Containments]"): cur = None
        continue
    if cur and re.fullmatch(r"plugin=org\.kde\.plasma\.(kickoff|kicker|kickerdash)", line):
        out.append(" ".join(cur))
print("\n".join(out))
PY
)"

if [[ -z "$PAIRS" ]]; then
    warn "Couldn't find an app launcher widget in $RC"
    exit 1
fi

# Stop the panel, edit config while it's not running (so it can't overwrite us), start it again
log "Restarting the Plasma panel..."
if systemctl --user is-active --quiet plasma-plasmashell.service; then
    USE_SYSTEMD=1; systemctl --user stop plasma-plasmashell.service
else
    USE_SYSTEMD=0; kquitapp6 plasmashell 2>/dev/null || kquitapp5 plasmashell 2>/dev/null
fi
sleep 2

while read -r C A; do
    [[ -z "$C" ]] && continue
    "$KWRITE" --file "$RC" --group Containments --group "$C" --group Applets --group "$A" \
        --group Configuration --group General --key icon "$ICON_VALUE"
    log "Launcher icon set (containment $C, applet $A) -> $ICON_VALUE"
done <<< "$PAIRS"

if [[ $USE_SYSTEMD -eq 1 ]]; then
    systemctl --user start plasma-plasmashell.service
else
    nohup kstart plasmashell >/dev/null 2>&1 &
    disown
fi
sleep 3
# ---------------- 3. PANELS ----------------
log "Step 3/4: taskbar cleanup + top panel"

read -r -d '' PANEL_JS << 'JS'
var removeTypes = [
    "org.kde.plasma.panelspacer",
    "org.kde.plasma.marginsseparator",
    "org.kde.plasma.systemtray",
    "org.kde.plasma.digitalclock"
];
var removed = 0;
var hasTop = false;
var existing = panels();
for (var i = 0; i < existing.length; i++) {
    var p = existing[i];
    if (p.location == "top") {
        hasTop = true;   // already have a top panel: leave its widgets alone
    } else {
        var ws = p.widgets();
        for (var j = 0; j < ws.length; j++) {
            if (removeTypes.indexOf(ws[j].type) !== -1) { ws[j].remove(); removed++; }
        }
    }
    p.hiding = "autohide";
    p.lengthMode = "fit";
    p.alignment = "center";
    p.floating = true;
}
var added = false;
if (!hasTop) {
    var top = new Panel;
    top.location = "top";
    top.height = 32;
    top.hiding = "autohide";
    top.lengthMode = "fit";
    top.alignment = "center";
    top.floating = true;
    top.addWidget("org.kde.plasma.trash");
    top.addWidget("org.kde.plasma.digitalclock");
    top.addWidget("org.kde.plasma.volume");
    added = true;
}
print("removed " + removed + " widgets, top panel added: " + added);
JS

QD="$(command -v qdbus6 || command -v qdbus-qt6 || command -v qdbus)"
if [[ -z "$QD" ]]; then
    warn "qdbus not found (install qt6-tools), skipping panel changes."
else
    for try in 1 2 3 4 5 6 7 8 9 10; do
        if RESULT="$("$QD" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$PANEL_JS" 2>&1)"; then
            log "Panels updated. ${RESULT}"
            break
        fi
        sleep 2
    done
    [[ -z "${RESULT:-}" ]] && warn "Couldn't reach Plasma to change the panels."
    sleep 3
fi

# ---------------- 4. WALLPAPER ----------------
log "Step 4/4: wallpaper"

# Prefer a file called wallpaper.*, otherwise take any other image in the project folder
WALL="$(find "$SCRIPT_DIR" -maxdepth 2 -type f -iname 'wallpaper*' \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | head -n1)"
if [[ -z "$WALL" ]]; then
    WALL="$(find "$SCRIPT_DIR" -maxdepth 2 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) ! -iname 'acorn*' 2>/dev/null | head -n1)"
fi

if [[ -z "$WALL" ]]; then
    warn "No wallpaper found next to the script. Add an image called wallpaper.jpg (or .png/.webp) and re-run."
elif ! command -v plasma-apply-wallpaperimage >/dev/null; then
    warn "plasma-apply-wallpaperimage not found, skipping wallpaper."
else
    mkdir -p "$HOME/.local/share/big-squirrel"
    WALL_DEST="$HOME/.local/share/big-squirrel/wallpaper.${WALL##*.}"
    cp "$WALL" "$WALL_DEST"
    plasma-apply-wallpaperimage "$WALL_DEST" && log "Wallpaper set: $WALL"
fi

log "Done! Move your mouse to the bottom/top edge of the screen to reveal the panels."
