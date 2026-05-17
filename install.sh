#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# StreamLink — installer
# Supporta: Ubuntu, Debian, Fedora, Arch Linux
# Installa dipendenze + ProtonVPN CLI + StreamLink in ~/.local/lib/streamlink/
# ─────────────────────────────────────────────────────────────────────────────
set -e

INSTALL_DIR="$HOME/.local/lib/streamlink"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"

# ── Colori ────────────────────────────────────────────────────────────────────
G="\033[32m"; R="\033[31m"; Y="\033[33m"; B="\033[1m"; N="\033[0m"
ok()   { echo -e "${G}${B}  ✓${N} $*"; }
err()  { echo -e "${R}${B}  ✗${N} $*"; }
info() { echo -e "${B}  →${N} $*"; }
warn() { echo -e "${Y}${B}  ⚠${N} $*"; }

echo ""
echo -e "${B}══════════════════════════════════════${N}"
echo -e "${B}   StreamLink — Installazione          ${N}"
echo -e "${B}══════════════════════════════════════${N}"
echo ""

# ── Rileva distro ─────────────────────────────────────────────────────────────
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID="${ID,,}"         # ubuntu, debian, fedora, arch, ...
        DISTRO_LIKE="${ID_LIKE,,}"  # "debian", "rhel fedora", ...
    else
        DISTRO_ID="unknown"
        DISTRO_LIKE=""
    fi

    if [[ "$DISTRO_ID" == "ubuntu" || "$DISTRO_LIKE" == *"ubuntu"* || "$DISTRO_LIKE" == *"debian"* ]]; then
        DISTRO_FAMILY="debian"
    elif [[ "$DISTRO_ID" == "debian" ]]; then
        DISTRO_FAMILY="debian"
    elif [[ "$DISTRO_ID" == "fedora" || "$DISTRO_LIKE" == *"fedora"* || "$DISTRO_LIKE" == *"rhel"* ]]; then
        DISTRO_FAMILY="fedora"
    elif [[ "$DISTRO_ID" == "arch" || "$DISTRO_LIKE" == *"arch"* ]]; then
        DISTRO_FAMILY="arch"
    else
        DISTRO_FAMILY="unknown"
    fi

    info "Distro rilevata: ${DISTRO_ID} (famiglia: ${DISTRO_FAMILY})"
}

detect_distro

if [[ "$DISTRO_FAMILY" == "unknown" ]]; then
    warn "Distro non riconosciuta. Provo con apt, altrimenti installa manualmente."
    DISTRO_FAMILY="debian"
fi

# ── Installa pacchetti di sistema ─────────────────────────────────────────────
install_pkg_debian() {
    info "Aggiornamento lista pacchetti…"
    sudo apt-get update -qq
    info "Installazione: $*"
    sudo apt-get install -y "$@"
}

install_pkg_fedora() {
    info "Installazione: $*"
    sudo dnf install -y "$@"
}

install_pkg_arch() {
    info "Installazione: $*"
    sudo pacman -S --noconfirm "$@"
}

install_pkg() {
    case "$DISTRO_FAMILY" in
        debian) install_pkg_debian "$@" ;;
        fedora) install_pkg_fedora "$@" ;;
        arch)   install_pkg_arch   "$@" ;;
    esac
}

# ── Controlla e installa dipendenze base ──────────────────────────────────────
echo ""
echo -e "${B}[1/4] Dipendenze di sistema${N}"

# python3
if command -v python3 &>/dev/null; then
    ok "python3 già installato"
else
    warn "python3 non trovato — installo…"
    install_pkg python3
fi

# wget (serve per scaricare il repo ProtonVPN)
if command -v wget &>/dev/null; then
    ok "wget già installato"
else
    warn "wget non trovato — installo…"
    install_pkg wget
fi

# PyGObject (GTK4 + libadwaita bindings Python)
if python3 -c "import gi; gi.require_version('Gtk','4.0'); gi.require_version('Adw','1')" 2>/dev/null; then
    ok "PyGObject (GTK4 + Adw) già installato"
else
    warn "PyGObject mancante — installo…"
    case "$DISTRO_FAMILY" in
        debian)
            install_pkg_debian python3-gi python3-gi-cairo gir1.2-gtk-4.0 gir1.2-adw-1
            ;;
        fedora)
            install_pkg_fedora python3-gobject gtk4 libadwaita
            ;;
        arch)
            install_pkg_arch python-gobject gtk4 libadwaita
            ;;
    esac
fi

# NetworkManager / nmcli
if command -v nmcli &>/dev/null; then
    ok "NetworkManager (nmcli) già installato"
else
    warn "nmcli non trovato — installo…"
    case "$DISTRO_FAMILY" in
        debian) install_pkg_debian network-manager ;;
        fedora) install_pkg_fedora NetworkManager ;;
        arch)   install_pkg_arch   networkmanager ;;
    esac
fi

# gnome-keyring (richiesto da ProtonVPN CLI)
if command -v gnome-keyring &>/dev/null || \
   [ -f /usr/lib/gnome-keyring-daemon ] || \
   [ -f /usr/bin/gnome-keyring-daemon ]; then
    ok "gnome-keyring già installato"
else
    warn "gnome-keyring mancante — installo (richiesto da ProtonVPN CLI)…"
    case "$DISTRO_FAMILY" in
        debian) install_pkg_debian gnome-keyring ;;
        fedora) install_pkg_fedora gnome-keyring ;;
        arch)   install_pkg_arch   gnome-keyring ;;
    esac
fi

# firefox
if command -v firefox &>/dev/null || \
   flatpak list 2>/dev/null | grep -q "org.mozilla.firefox"; then
    ok "Firefox già installato"
else
    warn "Firefox non trovato — installo…"
    case "$DISTRO_FAMILY" in
        debian) install_pkg_debian firefox ;;
        fedora) install_pkg_fedora firefox ;;
        arch)   install_pkg_arch   firefox ;;
    esac
fi

# ── Installa ProtonVPN CLI ────────────────────────────────────────────────────
echo ""
echo -e "${B}[2/4] ProtonVPN CLI${N}"

if command -v protonvpn &>/dev/null; then
    ok "protonvpn CLI già installato ($(protonvpn --version 2>/dev/null | head -1 || echo 'versione sconosciuta'))"
else
    warn "ProtonVPN CLI non trovato — procedo con l'installazione ufficiale…"

    case "$DISTRO_FAMILY" in

        debian)
            # ── Debian / Ubuntu ──────────────────────────────────────────────
            # Fonte: https://protonvpn.com/support/official-linux-vpn-debian/
            #        https://protonvpn.com/support/official-linux-vpn-ubuntu/
            #
            # Passo 1: scarica il pacchetto che configura il repo Proton
            info "Download pacchetto repo ProtonVPN…"
            wget -q "https://repo.protonvpn.com/debian/dists/stable/main/binary-all/protonvpn-stable-release_1.0.8_all.deb" \
                -O /tmp/protonvpn-stable-release.deb

            # Passo 2: installa il pacchetto repo (configura apt sources + chiavi GPG)
            info "Installazione pacchetto repo ProtonVPN…"
            sudo dpkg -i /tmp/protonvpn-stable-release.deb

            # Passo 3: aggiorna apt con il nuovo repo
            info "Aggiornamento apt con il nuovo repo Proton…"
            sudo apt-get update -qq

            # Passo 4: installa proton-vpn-cli
            info "Installazione proton-vpn-cli…"
            sudo apt-get install -y proton-vpn-cli

            rm -f /tmp/protonvpn-stable-release.deb
            ;;

        fedora)
            # ── Fedora ───────────────────────────────────────────────────────
            # Fonte: https://protonvpn.com/support/official-linux-vpn-fedora/
            #
            # Passo 1: rileva versione Fedora e scarica il repo corrispondente
            FEDORA_VER=$(cat /etc/fedora-release | grep -oP '\d+' | head -1)
            info "Fedora versione: ${FEDORA_VER}"
            info "Download pacchetto repo ProtonVPN per Fedora ${FEDORA_VER}…"
            wget -q "https://repo.protonvpn.com/fedora-${FEDORA_VER}-stable/protonvpn-stable-release/protonvpn-stable-release-1.0.4-1.noarch.rpm" \
                -O /tmp/protonvpn-stable-release.rpm

            # Passo 2: installa il pacchetto repo
            info "Installazione pacchetto repo ProtonVPN…"
            sudo dnf install -y /tmp/protonvpn-stable-release.rpm

            # Passo 3: installa proton-vpn-cli
            # (dnf chiederà di accettare la chiave OpenPGP — risposta automatica: y)
            info "Installazione proton-vpn-cli…"
            sudo dnf install -y proton-vpn-cli

            rm -f /tmp/protonvpn-stable-release.rpm
            ;;

        arch)
            # ── Arch Linux ───────────────────────────────────────────────────
            # Fonte: https://protonvpn.com/support/linux-cli/
            # Disponibile direttamente nei repo extra di Arch
            info "Installazione proton-vpn-cli da repo Arch…"
            sudo pacman -S --noconfirm proton-vpn-cli
            ;;
    esac

    # Verifica installazione
    if command -v protonvpn &>/dev/null; then
        ok "ProtonVPN CLI installato correttamente"
    else
        err "Installazione ProtonVPN CLI fallita"
        warn "Installa manualmente seguendo: https://protonvpn.com/support/linux-cli"
        warn "Poi esegui di nuovo questo installer."
        exit 1
    fi
fi

# ── Installa StreamLink ───────────────────────────────────────────────────────
echo ""
echo -e "${B}[3/4] StreamLink${N}"

mkdir -p "$INSTALL_DIR"
cp streamlink.py "$INSTALL_DIR/streamlink.py"
chmod 755 "$INSTALL_DIR/streamlink.py"
ok "File copiato in $INSTALL_DIR"

# Wrapper nel PATH utente
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/streamlink" << EOF
#!/bin/bash
exec python3 "$INSTALL_DIR/streamlink.py" "\$@"
EOF
chmod +x "$BIN_DIR/streamlink"
ok "Wrapper creato in $BIN_DIR/streamlink"

# Assicura che ~/.local/bin sia nel PATH
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    warn "~/.local/bin non è nel PATH. Lo aggiungo a ~/.bashrc…"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    warn "Esegui: source ~/.bashrc  (oppure riapri il terminale)"
fi

# .desktop per il menu GNOME
mkdir -p "$DESKTOP_DIR"
cat > "$DESKTOP_DIR/streamlink.desktop" << EOF
[Desktop Entry]
Name=StreamLink
Comment=Launcher StreamingCommunity con ProtonVPN
Exec=$BIN_DIR/streamlink
Icon=network-vpn
Terminal=false
Type=Application
Categories=Network;
StartupNotify=true
EOF
update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
ok ".desktop creato per il menu GNOME"

# ── Riepilogo ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${B}[4/4] Riepilogo${N}"
echo ""
ok "Installazione completata!"
echo ""
echo -e "  Avvia con:  ${B}streamlink${N}"
echo -e "  Oppure cerca ${B}StreamLink${N} nel menu GNOME"
echo ""
echo -e "  ${Y}Prossimo passo:${N} accedi a ProtonVPN con:"
echo -e "  ${B}protonvpn signin${N}"
echo ""
echo -e "  Aggiornamenti automatici da:"
echo -e "  ${B}https://github.com/FlavioCoding/stream-link${N}"
echo ""
