#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# StreamLink — bootstrap: python3 + GTK4, poi lancia l'installer grafico
# ─────────────────────────────────────────────────────────────────────────────
set -e

B="\033[1m"; N="\033[0m"; G="\033[32m"; R="\033[31m"
ok()   { echo -e "${G}${B}  ✓${N} $*"; }
err()  { echo -e "${R}${B}  ✗${N} $*"; exit 1; }
info() { echo -e "${B}  →${N} $*"; }

# Rileva famiglia distro
DISTRO_FAMILY="debian"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    ID_L="${ID,,}"; LIKE_L="${ID_LIKE,,}"
    if   [[ "$ID_L" == "fedora" || "$LIKE_L" == *"fedora"* || "$LIKE_L" == *"rhel"* ]]; then
        DISTRO_FAMILY="fedora"
    elif [[ "$ID_L" == "arch" || "$LIKE_L" == *"arch"* ]]; then
        DISTRO_FAMILY="arch"
    fi
fi

echo ""
echo -e "${B}  StreamLink — preparazione installer${N}"
echo ""

# python3
if ! command -v python3 &>/dev/null; then
    info "Installazione python3…"
    case "$DISTRO_FAMILY" in
        debian) sudo apt-get update -qq && sudo apt-get install -y python3 ;;
        fedora) sudo dnf install -y python3 ;;
        arch)   sudo pacman -S --noconfirm python3 ;;
    esac
fi
ok "python3"

# PyGObject + GTK4 + libadwaita
if ! python3 -c "import gi; gi.require_version('Gtk','4.0'); gi.require_version('Adw','1')" 2>/dev/null; then
    info "Installazione interfaccia grafica (GTK4 + libadwaita)…"
    case "$DISTRO_FAMILY" in
        debian) sudo apt-get update -qq && sudo apt-get install -y \
                    python3-gi python3-gi-cairo gir1.2-gtk-4.0 gir1.2-adw-1 ;;
        fedora) sudo dnf install -y python3-gobject gtk4 libadwaita ;;
        arch)   sudo pacman -S --noconfirm python-gobject gtk4 libadwaita ;;
    esac
fi
ok "interfaccia grafica"

if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
    err "Nessun display grafico. Esegui da un ambiente desktop."
fi

echo ""
info "Avvio installer…"

export STREAMLINK_DISTRO_FAMILY="$DISTRO_FAMILY"
export STREAMLINK_INSTALL_DIR="$HOME/.local/lib/streamlink"
export STREAMLINK_BIN_DIR="$HOME/.local/bin"
export STREAMLINK_DESKTOP_DIR="$HOME/.local/share/applications"

python3 - <<'INSTALLER_END'
#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
# Sicurezza credenziali ProtonVPN:
#   - Raccolte in Gtk.Entry (never written to disk)
#   - Passate via stdin al processo figlio (non visibili in "ps aux")
#   - Trasmesse a ProtonVPN via HTTPS dalla CLI ufficiale
#   - Non loggate in nessun punto
#   - Limite noto: stringhe Python immutabili, non azzerabili senza ctypes
# ─────────────────────────────────────────────────────────────────────────────
import gi
gi.require_version('Gtk', '4.0')
gi.require_version('Adw', '1')

from gi.repository import Gtk, Adw, GLib, Gio, Gdk
import sys, os, math, time, threading, shutil, tempfile
import urllib.request, urllib.error, json, subprocess

DISTRO       = os.environ.get("STREAMLINK_DISTRO_FAMILY", "debian")
INSTALL_DIR  = os.environ.get("STREAMLINK_INSTALL_DIR",   os.path.expanduser("~/.local/lib/streamlink"))
BIN_DIR      = os.environ.get("STREAMLINK_BIN_DIR",       os.path.expanduser("~/.local/bin"))
DESKTOP_DIR  = os.environ.get("STREAMLINK_DESKTOP_DIR",   os.path.expanduser("~/.local/share/applications"))
DESKTOP_HOME = os.path.expanduser("~/Desktop")
GITHUB_API   = "https://api.github.com/repos/Flavio-coding/stream-link/releases"


# ─── Helpers di sistema ───────────────────────────────────────────────────────

def cmd_exists(name):
    return shutil.which(name) is not None

def sudo_run(args, timeout=120):
    return subprocess.run(["sudo"] + args, capture_output=True, text=True, timeout=timeout)

def pkg_install(*pkgs):
    if DISTRO == "fedora":
        sudo_run(["dnf", "install", "-y"] + list(pkgs))
    elif DISTRO == "arch":
        sudo_run(["pacman", "-S", "--noconfirm"] + list(pkgs))
    else:
        sudo_run(["apt-get", "install", "-y", "-qq"] + list(pkgs))

def protonvpn_is_signed_in():
    try:
        r = subprocess.run(["protonvpn", "account"],
                           capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            return True
        out = (r.stdout + r.stderr).lower()
        if any(p in out for p in ["not logged", "not signed", "sign in", "login"]):
            return False
        # Fallback: check status
        r2 = subprocess.run(["protonvpn", "status"],
                            capture_output=True, text=True, timeout=10)
        out2 = (r2.stdout + r2.stderr).lower()
        return not any(p in out2 for p in ["not logged", "not signed", "sign in", "login first"])
    except Exception:
        return False


# ─── Finestra installer ────────────────────────────────────────────────────────

class InstallerWindow(Adw.ApplicationWindow):
    _BAR_CHUNK = 0.22
    _BAR_STEP  = 0.016

    def __init__(self, **kw):
        super().__init__(**kw)
        self.set_title("StreamLink — Installer")
        self.set_default_size(460, 500)
        self.set_resizable(False)
        self._add_desktop   = True
        self._bar_pos       = 0.0
        self._bar_dir       = 1
        self._bar_src       = None
        self._signin_event  = None
        self._signin_creds  = None   # (username, password) | None
        self._signin_error  = None   # messaggio di errore da mostrare nel dialog
        self._build()
        self._load_css()

    # ── CSS ───────────────────────────────────────────────────────────────────

    def _load_css(self):
        css = b"""
        .success     { color: @success_color; }
        .error-color { color: @error_color;   }
        .mono        { font-family: monospace; font-size: 0.9em; }
        .hint-panel  {
            background-color: alpha(@card_bg_color, 0.6);
            border-radius: 12px;
            padding: 12px 20px;
        }
        .field-card {
            background-color: alpha(@card_bg_color, 0.6);
            border-radius: 12px;
            border: 1px solid alpha(@borders, 0.35);
            padding: 6px 14px 8px 14px;
        }
        .field-caption {
            font-size: 0.78em;
            color: alpha(@window_fg_color, 0.55);
        }
        .field-card text {
            background-color: transparent;
            box-shadow: none;
            outline: none;
        }
        .field-card text:focus {
            box-shadow: none;
            outline: none;
        }
        """
        p = Gtk.CssProvider()
        p.load_from_data(css)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), p, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    # ── Barra rimbalzante ─────────────────────────────────────────────────────

    def _start_bounce(self):
        if self._bar_src:
            GLib.source_remove(self._bar_src)
        def _tick():
            self._bar_pos += self._BAR_STEP * self._bar_dir
            if self._bar_pos + self._BAR_CHUNK >= 1.0:
                self._bar_pos = 1.0 - self._BAR_CHUNK
                self._bar_dir = -1
            elif self._bar_pos <= 0.0:
                self._bar_pos = 0.0
                self._bar_dir = 1
            self._canvas.queue_draw()
            return True
        self._bar_src = GLib.timeout_add(18, _tick)

    def _stop_bounce(self):
        if self._bar_src:
            GLib.source_remove(self._bar_src)
            self._bar_src = None

    def _on_canvas_draw(self, area, cr, w, h):
        r = h / 2.0
        cr.set_source_rgba(0.5, 0.5, 0.5, 0.25)
        self._rrect(cr, 0, 0, w, h, r); cr.fill()
        cr.set_source_rgb(0.212, 0.518, 0.894)
        self._rrect(cr, self._bar_pos * w, 0, self._BAR_CHUNK * w, h, r); cr.fill()

    def _rrect(self, cr, x, y, w, h, r):
        cr.new_sub_path()
        cr.arc(x+r,   y+r,   r, math.pi,       3*math.pi/2)
        cr.arc(x+w-r, y+r,   r, 3*math.pi/2,   0)
        cr.arc(x+w-r, y+h-r, r, 0,              math.pi/2)
        cr.arc(x+r,   y+h-r, r, math.pi/2,      math.pi)
        cr.close_path()

    # ── Timing (minimo 2 secondi per schermata) ───────────────────────────────

    def _wait(self, t0, minimum=2.0):
        elapsed = time.time() - t0
        if elapsed < minimum:
            time.sleep(minimum - elapsed)

    # ── Build UI ──────────────────────────────────────────────────────────────

    def _build(self):
        hb = Adw.HeaderBar()
        hb.add_css_class("flat")
        hb.set_show_end_title_buttons(True)

        self._stack = Gtk.Stack()
        self._stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        self._stack.set_transition_duration(180)
        self._stack.set_hexpand(True)
        self._stack.set_vexpand(True)
        self._stack.add_named(Gtk.Box(), "blank")

        self._build_welcome()
        self._build_installing()
        self._build_success()
        self._build_error()

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.set_vexpand(True)
        box.append(self._stack)

        view = Adw.ToolbarView()
        view.add_top_bar(hb)
        view.set_content(box)
        self.set_content(view)
        self._stack.set_visible_child_name("welcome")

    def _build_welcome(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        root.set_valign(Gtk.Align.CENTER)
        root.set_halign(Gtk.Align.FILL)
        root.set_margin_start(32); root.set_margin_end(32)

        icon = Gtk.Image.new_from_icon_name("network-vpn-symbolic")
        icon.set_pixel_size(72)
        icon.add_css_class("dim-label")
        icon.set_margin_bottom(12)

        title = Gtk.Label(label="StreamLink")
        title.add_css_class("title-1")

        sub = Gtk.Label(label="Launcher per StreamingCommunity\ncon ProtonVPN")
        sub.add_css_class("body"); sub.add_css_class("dim-label")
        sub.set_justify(Gtk.Justification.CENTER)
        sub.set_margin_top(4); sub.set_margin_bottom(24)

        opts = Gtk.ListBox()
        opts.set_selection_mode(Gtk.SelectionMode.NONE)
        opts.add_css_class("boxed-list")
        opts.set_margin_bottom(28)

        row = Adw.SwitchRow()
        row.set_title("Collegamento sul Desktop")
        row.set_subtitle("Aggiunge un'icona nella cartella Desktop")
        row.set_active(True)
        row.connect("notify::active",
            lambda r, _: setattr(self, "_add_desktop", r.get_active()))
        opts.append(row)

        btn = Gtk.Button(label="Installa")
        btn.add_css_class("pill")
        btn.add_css_class("suggested-action")
        btn.set_size_request(160, 44)
        btn.set_halign(Gtk.Align.CENTER)
        btn.connect("clicked", self._on_install)

        for w in (icon, title, sub, opts, btn):
            root.append(w)
        self._stack.add_named(root, "welcome")

    def _build_installing(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.set_valign(Gtk.Align.CENTER)
        box.set_halign(Gtk.Align.CENTER)

        self._inst_icon = Gtk.Image.new_from_icon_name("content-loading-symbolic")
        self._inst_icon.set_pixel_size(64)
        self._inst_icon.set_margin_bottom(16)

        self._inst_title = Gtk.Label(label="")
        self._inst_title.add_css_class("title-1")
        self._inst_title.set_justify(Gtk.Justification.CENTER)

        self._inst_sub = Gtk.Label(label="")
        self._inst_sub.add_css_class("body")
        self._inst_sub.add_css_class("dim-label")
        self._inst_sub.set_justify(Gtk.Justification.CENTER)
        self._inst_sub.set_margin_top(6)

        self._canvas = Gtk.DrawingArea()
        self._canvas.set_size_request(280, 6)
        self._canvas.set_halign(Gtk.Align.CENTER)
        self._canvas.set_margin_top(20)
        self._canvas.set_draw_func(self._on_canvas_draw)

        for w in (self._inst_icon, self._inst_title, self._inst_sub, self._canvas):
            box.append(w)
        self._stack.add_named(box, "installing")

    def _build_success(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        root.set_valign(Gtk.Align.CENTER)
        root.set_halign(Gtk.Align.FILL)
        root.set_margin_start(32); root.set_margin_end(32)

        icon = Gtk.Image.new_from_icon_name("emblem-ok-symbolic")
        icon.set_pixel_size(64); icon.add_css_class("success")
        icon.set_margin_bottom(8)

        title = Gtk.Label(label="Installazione completata!")
        title.add_css_class("title-1")

        sub = Gtk.Label(label="StreamLink è pronto all'uso.")
        sub.add_css_class("dim-label")
        sub.set_margin_top(4); sub.set_margin_bottom(20)

        hint = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        hint.add_css_class("hint-panel"); hint.set_margin_bottom(24)
        h1 = Gtk.Label(label="Prossimo passo")
        h1.add_css_class("caption"); h1.add_css_class("dim-label")
        h1.set_halign(Gtk.Align.START)
        h2 = Gtk.Label(label="protonvpn signin")
        h2.add_css_class("mono"); h2.set_halign(Gtk.Align.START)
        hint.append(h1); hint.append(h2)

        btns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        btns.set_halign(Gtk.Align.CENTER)

        b_launch = Gtk.Button(label="Avvia StreamLink")
        b_launch.add_css_class("pill"); b_launch.add_css_class("suggested-action")
        b_launch.connect("clicked", self._on_launch)

        b_close = Gtk.Button(label="Chiudi")
        b_close.add_css_class("pill")
        b_close.connect("clicked", lambda _: self.get_application().quit())

        btns.append(b_launch); btns.append(b_close)
        for w in (icon, title, sub, hint, btns):
            root.append(w)
        self._stack.add_named(root, "success")

    def _build_error(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        box.set_valign(Gtk.Align.CENTER); box.set_halign(Gtk.Align.CENTER)
        box.set_margin_start(32); box.set_margin_end(32)

        icon = Gtk.Image.new_from_icon_name("dialog-error-symbolic")
        icon.set_pixel_size(64); icon.add_css_class("error-color")

        self._err_title = Gtk.Label()
        self._err_title.add_css_class("title-2")
        self._err_title.set_justify(Gtk.Justification.CENTER)
        self._err_title.set_wrap(True); self._err_title.set_max_width_chars(28)

        self._err_body = Gtk.Label()
        self._err_body.add_css_class("body"); self._err_body.add_css_class("dim-label")
        self._err_body.set_justify(Gtk.Justification.CENTER)
        self._err_body.set_wrap(True); self._err_body.set_max_width_chars(36)

        btn = Gtk.Button(label="↺  Riprova")
        btn.add_css_class("pill"); btn.add_css_class("suggested-action")
        btn.set_halign(Gtk.Align.CENTER)
        btn.connect("clicked", lambda _: self._goto("welcome"))

        for w in (icon, self._err_title, self._err_body, btn):
            box.append(w)
        self._stack.add_named(box, "error")

    # ── Transizioni ───────────────────────────────────────────────────────────

    def _goto(self, name):
        def _blank():
            self._stack.set_visible_child_name("blank")
            GLib.timeout_add(100, _target)
            return False
        def _target():
            self._stack.set_visible_child_name(name)
            return False
        GLib.idle_add(_blank)

    def _set_step(self, icon_name, title, sub=""):
        def _f():
            self._inst_icon.set_from_icon_name(icon_name)
            self._inst_title.set_label(title)
            self._inst_sub.set_label(sub)
            self._stack.set_visible_child_name("installing")
            return False
        GLib.idle_add(_f)

    def _show_error(self, title, body):
        GLib.idle_add(self._stop_bounce)
        def _f():
            self._err_title.set_label(title)
            self._err_body.set_label(body)
            return False
        GLib.idle_add(_f)
        self._goto("error")

    # ── Dialog signin ProtonVPN ───────────────────────────────────────────────

    def _show_signin_dialog(self):
        win = Gtk.Window()
        win.set_title("ProtonVPN — Accesso")
        win.set_modal(True)
        win.set_transient_for(self)
        win.set_default_size(380, -1)
        win.set_resizable(False)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        content.set_margin_top(20)
        content.set_margin_bottom(24)
        content.set_margin_start(24)
        content.set_margin_end(24)

        desc = Gtk.Label(label="Inserisci le credenziali del tuo\naccount ProtonVPN")
        desc.add_css_class("body"); desc.add_css_class("dim-label")
        desc.set_justify(Gtk.Justification.CENTER)
        desc.set_margin_top(8)
        desc.set_margin_bottom(20)

        # ── campo username ──────────────────────────────────────────────────────
        u_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        u_card.add_css_class("field-card")
        u_card.set_margin_bottom(10)
        u_lbl = Gtk.Label(label="Username")
        u_lbl.add_css_class("field-caption")
        u_lbl.set_halign(Gtk.Align.START)
        # Gtk.Text = widget testo grezzo, niente frame né outline blu di focus
        u_text = Gtk.Text()
        u_text.set_input_purpose(Gtk.InputPurpose.EMAIL)
        u_card.append(u_lbl)
        u_card.append(u_text)

        # ── campo password ──────────────────────────────────────────────────────
        p_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        p_card.add_css_class("field-card")
        p_card.set_margin_bottom(16)
        p_lbl = Gtk.Label(label="Password")
        p_lbl.add_css_class("field-caption")
        p_lbl.set_halign(Gtk.Align.START)
        p_text = Gtk.Text()
        p_text.set_visibility(False)          # pallini ●●●●
        p_text.set_input_purpose(Gtk.InputPurpose.PASSWORD)
        p_card.append(p_lbl)
        p_card.append(p_text)

        # ── etichetta errore (visibile solo dopo credenziali errate) ────────────
        err_lbl = Gtk.Label(label=self._signin_error or "")
        err_lbl.add_css_class("error-color")
        err_lbl.add_css_class("caption")
        err_lbl.set_halign(Gtk.Align.CENTER)
        err_lbl.set_justify(Gtk.Justification.CENTER)
        err_lbl.set_margin_bottom(14)
        err_lbl.set_visible(bool(self._signin_error))

        btns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        btns.set_halign(Gtk.Align.CENTER)

        b_cancel = Gtk.Button(label="Annulla")
        b_cancel.add_css_class("pill")
        b_cancel.connect("clicked", lambda _: self._signin_cancel(win))

        b_ok = Gtk.Button(label="Accedi")
        b_ok.add_css_class("pill")
        b_ok.add_css_class("suggested-action")
        b_ok.connect("clicked",
            lambda _: self._signin_ok(win, u_text, p_text))

        # Invio su username → sposta focus a password; invio su password → conferma
        u_text.connect("activate", lambda _: p_text.grab_focus())
        p_text.connect("activate",
            lambda _: self._signin_ok(win, u_text, p_text))

        btns.append(b_cancel); btns.append(b_ok)

        content.append(desc)
        content.append(u_card)
        content.append(p_card)
        content.append(err_lbl)
        content.append(btns)

        win.set_child(content)
        win.present()
        u_text.grab_focus()
        return False

    def _signin_ok(self, win, u_text, p_text):
        username = u_text.get_buffer().get_text().strip()
        password = p_text.get_buffer().get_text()
        if not username or not password:
            return
        self._signin_creds = (username, password)
        win.close()
        if self._signin_event:
            self._signin_event.set()

    def _signin_cancel(self, win):
        self._signin_creds = None
        win.close()
        if self._signin_event:
            self._signin_event.set()

    # ── Azioni ────────────────────────────────────────────────────────────────

    def _on_install(self, _):
        self._goto("installing")
        GLib.timeout_add(250, self._launch_thread)

    def _launch_thread(self):
        GLib.idle_add(self._start_bounce)
        threading.Thread(target=self._install_thread, daemon=True).start()
        return False

    def _on_launch(self, _):
        try:
            subprocess.Popen([os.path.join(BIN_DIR, "streamlink")],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
        self.get_application().quit()

    # ── Thread installazione ──────────────────────────────────────────────────

    def _install_thread(self):

        # 1 — Internet
        t = time.time()
        self._set_step("network-wireless-symbolic", "Verifica internet", "Ping 8.8.8.8…")
        ok_net = subprocess.run(["ping", "-c", "1", "-W", "3", "8.8.8.8"],
                                capture_output=True, timeout=6).returncode == 0
        self._wait(t)
        if not ok_net:
            self._show_error("Nessuna connessione", "Controlla il WiFi o il cavo di rete.")
            return

        # 2 — Dipendenze di sistema
        deps = {
            "wget":          (["wget"],         "wget"),
            "nmcli":         (["network-manager"] if DISTRO != "arch" else ["networkmanager"],
                              "NetworkManager"),
            "gnome-keyring": (["gnome-keyring"], "gnome-keyring"),
            "firefox":       (["firefox"],       "Firefox"),
        }

        t = time.time()
        self._set_step("preferences-system-symbolic", "Dipendenze", "Verifica in corso…")
        missing = {k: v for k, v in deps.items() if not cmd_exists(k)}
        self._wait(t)

        for binary, (pkgs, label) in missing.items():
            t = time.time()
            self._set_step("preferences-system-symbolic",
                           f"Installazione {label}",
                           "Potrebbe essere richiesta la password…")
            if DISTRO == "debian":
                sudo_run(["apt-get", "update", "-qq"])
            pkg_install(*pkgs)
            self._wait(t)

        # 3 — ProtonVPN CLI
        if not cmd_exists("protonvpn"):
            t = time.time()
            self._set_step("network-vpn-symbolic",
                           "ProtonVPN CLI", "Download repository ufficiale…")
            try:
                if DISTRO == "debian":
                    import re as _re
                    # Scopre automaticamente l'URL del .deb dall'indice del repo
                    deb_url = None
                    try:
                        _pkg_req = urllib.request.Request(
                            "https://repo.protonvpn.com/debian/dists/stable/"
                            "main/binary-all/Packages",
                            headers={"User-Agent": "StreamLink-Installer"})
                        with urllib.request.urlopen(_pkg_req, timeout=10) as _rp:
                            _pkgs = _rp.read().decode(errors="replace")
                        _m = _re.search(
                            r"Filename:\s+(.*?protonvpn-stable-release[^\s]+\.deb)",
                            _pkgs)
                        if _m:
                            deb_url = ("https://repo.protonvpn.com/debian/"
                                       + _m.group(1).strip())
                    except Exception:
                        pass
                    if not deb_url:
                        # URL di fallback aggiornato
                        deb_url = ("https://repo.protonvpn.com/debian/dists/stable/"
                                   "main/binary-all/protonvpn-stable-release_1.0.6-2_all.deb")
                    tmp = "/tmp/protonvpn-stable-release.deb"
                    urllib.request.urlretrieve(deb_url, tmp)
                    sudo_run(["dpkg", "-i", tmp])
                    sudo_run(["apt-get", "update", "-qq"])
                    sudo_run(["apt-get", "install", "-y", "protonvpn-cli"])
                    os.unlink(tmp)
                elif DISTRO == "fedora":
                    import re as _re
                    ver = _re.search(r'\d+', open("/etc/fedora-release").read()).group()
                    tmp = "/tmp/protonvpn-stable-release.rpm"
                    urllib.request.urlretrieve(
                        f"https://repo.protonvpn.com/fedora-{ver}-stable/"
                        "protonvpn-stable-release/protonvpn-stable-release-1.0.4-1.noarch.rpm",
                        tmp)
                    sudo_run(["dnf", "install", "-y", tmp])
                    sudo_run(["dnf", "install", "-y", "proton-vpn-cli"])
                    os.unlink(tmp)
                else:
                    sudo_run(["pacman", "-S", "--noconfirm", "proton-vpn-cli"])

                if not cmd_exists("protonvpn"):
                    self._show_error("ProtonVPN non installato",
                                     "Installa manualmente:\nhttps://protonvpn.com/support/linux-cli")
                    return
            except Exception as e:
                self._show_error("Errore ProtonVPN CLI", str(e))
                return
            self._wait(t)

        # 4 — Verifica accesso ProtonVPN
        t = time.time()
        self._set_step("system-lock-screen-symbolic",
                       "ProtonVPN", "Verifica accesso account…")
        signed_in = protonvpn_is_signed_in()
        self._wait(t)

        if not signed_in:
            self._signin_error = None          # reset per eventuale re-installazione
            while True:
                # Mostra dialog credenziali sul main thread; attendi risposta
                self._signin_event = threading.Event()
                self._signin_creds = None
                GLib.idle_add(self._show_signin_dialog)
                self._signin_event.wait(timeout=180)

                if self._signin_creds is None:
                    self._show_error("Accesso annullato",
                                     "Esegui 'protonvpn signin'\ndal terminale per procedere.")
                    return

                username, password = self._signin_creds
                t = time.time()
                self._set_step("system-lock-screen-symbolic",
                               "Accesso ProtonVPN", "Autenticazione in corso…")
                try:
                    proc = subprocess.Popen(
                        ["protonvpn", "signin"],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True)
                    _, stderr = proc.communicate(
                        input=f"{username}\n{password}\n", timeout=30)
                    if proc.returncode != 0:
                        # Credenziali errate: aggiorna errore e riapri il dialog
                        self._signin_error = "Username o password non corretti."
                        continue
                except subprocess.TimeoutExpired:
                    self._show_error("Timeout accesso",
                                     "Impossibile completare l'accesso.\nRiprova.")
                    return
                except Exception as e:
                    self._show_error("Errore accesso", str(e))
                    return
                self._wait(t)
                break   # accesso riuscito, prosegui installazione

        # 5 — Download streamlink.py
        t = time.time()
        self._set_step("network-receive-symbolic",
                       "Download StreamLink", "GitHub releases…")
        try:
            req = urllib.request.Request(GITHUB_API, headers={
                "User-Agent": "StreamLink-Installer",
                "Accept":     "application/vnd.github+json",
            })
            with urllib.request.urlopen(req, timeout=10) as r:
                releases = json.load(r)

            url = None
            for rel in releases:
                for asset in rel.get("assets", []):
                    if asset["name"].endswith(".py"):
                        url = asset["browser_download_url"]
                        break
                if url:
                    break

            if not url:
                self._show_error("Download fallito",
                                 "Nessun asset .py nelle release GitHub.")
                return

            req2 = urllib.request.Request(
                url, headers={"User-Agent": "StreamLink-Installer"})
            with urllib.request.urlopen(req2, timeout=30) as r2:
                content = r2.read()

        except urllib.error.URLError as e:
            self._show_error("Errore di rete", str(e.reason))
            return
        except Exception as e:
            self._show_error("Download fallito", str(e))
            return
        self._wait(t)

        # 6 — Copia file
        t = time.time()
        self._set_step("drive-harddisk-symbolic",
                       "Installazione", "Copia file in corso…")
        try:
            os.makedirs(INSTALL_DIR, exist_ok=True)
            tmp_fd, tmp_path = tempfile.mkstemp(suffix=".py")
            with os.fdopen(tmp_fd, "wb") as f:
                f.write(content)
            os.chmod(tmp_path, 0o755)
            shutil.move(tmp_path, os.path.join(INSTALL_DIR, "streamlink.py"))
        except Exception as e:
            self._show_error("Installazione fallita", str(e))
            return
        self._wait(t)

        # 7 — Wrapper + PATH
        t = time.time()
        self._set_step("system-run-symbolic",
                       "Configurazione", "Creazione comando streamlink…")
        try:
            os.makedirs(BIN_DIR, exist_ok=True)
            wrapper = os.path.join(BIN_DIR, "streamlink")
            with open(wrapper, "w") as f:
                f.write(f'#!/bin/bash\nexec python3 "{INSTALL_DIR}/streamlink.py" "$@"\n')
            os.chmod(wrapper, 0o755)
            bashrc = os.path.expanduser("~/.bashrc")
            try:
                txt = open(bashrc).read() if os.path.exists(bashrc) else ""
                if ".local/bin" not in txt:
                    with open(bashrc, "a") as f:
                        f.write('\nexport PATH="$HOME/.local/bin:$PATH"\n')
            except Exception:
                pass
        except Exception as e:
            self._show_error("Configurazione fallita", str(e))
            return
        self._wait(t)

        # 8 — Icone
        t = time.time()
        self._set_step("preferences-desktop-symbolic",
                       "Icone", "Creazione collegamenti…")
        entry = (
            "[Desktop Entry]\n"
            "Name=StreamLink\n"
            "Comment=Launcher StreamingCommunity con ProtonVPN\n"
            f"Exec={BIN_DIR}/streamlink\n"
            "Icon=network-vpn\n"
            "Terminal=false\n"
            "Type=Application\n"
            "Categories=Network;\n"
            "StartupNotify=true\n"
        )
        try:
            os.makedirs(DESKTOP_DIR, exist_ok=True)
            with open(os.path.join(DESKTOP_DIR, "streamlink.desktop"), "w") as f:
                f.write(entry)
            subprocess.run(["update-desktop-database", DESKTOP_DIR], capture_output=True)
        except Exception:
            pass
        if self._add_desktop:
            try:
                os.makedirs(DESKTOP_HOME, exist_ok=True)
                dest = os.path.join(DESKTOP_HOME, "streamlink.desktop")
                with open(dest, "w") as f:
                    f.write(entry)
                os.chmod(dest, 0o755)
                subprocess.run(["gio", "set", dest, "metadata::trusted", "true"],
                                capture_output=True)
            except Exception:
                pass
        self._wait(t)

        # Fine
        GLib.idle_add(self._stop_bounce)
        self._goto("success")


class InstallerApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id="it.streamlink.installer",
                         flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.connect("activate", lambda a: InstallerWindow(application=a).present())

sys.exit(InstallerApp().run([sys.argv[0]]))
INSTALLER_END
