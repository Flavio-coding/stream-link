#!/usr/bin/env python3
"""
StreamLink — Launcher per StreamingCommunity con ProtonVPN CLI
GTK4 + libadwaita — layout 650x400
"""

import gi
gi.require_version('Gtk', '4.0')
gi.require_version('Adw', '1')

from gi.repository import Gtk, Adw, GLib, Gio, Gdk, Pango
import subprocess
import threading
import urllib.request
import urllib.error
import re
import time
import math
import sys
import os
import configparser
import logging

# ─── Logger ───────────────────────────────────────────────────────────────────

class _ColorFormatter(logging.Formatter):
    RESET = "\033[0m"
    BOLD  = "\033[1m"
    COLORS = {
        logging.DEBUG:   "\033[36m",
        logging.INFO:    "\033[32m",
        logging.WARNING: "\033[33m",
        logging.ERROR:   "\033[31m",
    }
    NAMES = {
        logging.DEBUG:   "DBG",
        logging.INFO:    "INF",
        logging.WARNING: "WRN",
        logging.ERROR:   "ERR",
    }
    def format(self, record):
        ts    = self.formatTime(record, "%H:%M:%S")
        color = self.COLORS.get(record.levelno, "")
        lvl   = self.NAMES.get(record.levelno, record.levelname)
        msg   = record.getMessage()
        if sys.stderr.isatty():
            return f"{color}{self.BOLD}[{ts}] {lvl}{self.RESET}  {msg}"
        return f"[{ts}] {lvl}  {msg}"

_handler = logging.StreamHandler(sys.stderr)
_handler.setFormatter(_ColorFormatter())
logging.getLogger().setLevel(logging.DEBUG)
logging.getLogger().addHandler(_handler)
log = logging.getLogger("streamlink")

# ─────────────────────────────────────────────────────────────────────────────
VERSION       = "v1.0.0"
TELEGRAPH_URL = "https://telegra.ph/Link-Aggiornato-StreamingCommunity-09-29"
CONFIG_PATH   = os.path.expanduser("~/.config/streamlink.conf")
INSTALL_PATH  = os.path.expanduser("~/.local/lib/streamlink/streamlink.py")
GITHUB_API    = "https://api.github.com/repos/Flavio-coding/stream-link/releases/latest"

# ─── Config ───────────────────────────────────────────────────────────────────

def load_config():
    cfg = configparser.ConfigParser()
    cfg.read(CONFIG_PATH)
    return {"autostart": cfg.getboolean("streamlink", "autostart", fallback=False)}

def save_config(autostart: bool):
    cfg = configparser.ConfigParser()
    cfg["streamlink"] = {"autostart": str(autostart).lower()}
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    with open(CONFIG_PATH, "w") as f:
        cfg.write(f)

# ─── Aggiornamenti ───────────────────────────────────────────────────────────

def check_for_updates():
    import json
    import tempfile
    import shutil

    log.info("[UPDATE] Controllo aggiornamenti da GitHub…")
    log.info(f"[UPDATE] Versione locale: {VERSION}")

    try:
        req = urllib.request.Request(GITHUB_API, headers={
            "User-Agent": "StreamLink-Updater",
            "Accept": "application/vnd.github+json",
        })
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())

        remote_tag = data.get("tag_name", "")
        log.info(f"[UPDATE] Versione remota: {remote_tag}")

        if not remote_tag:
            log.warning("[UPDATE] tag_name vuoto nella risposta GitHub")
            return False, "Nessun tag trovato"

        def parse(tag):
            return tuple(int(x) for x in tag.lstrip("v").split(".") if x.isdigit())

        if parse(remote_tag) <= parse(VERSION):
            log.info("[UPDATE] Già all'ultima versione")
            return False, "Già aggiornato"

        download_url = None
        for asset in data.get("assets", []):
            if asset.get("name", "").endswith(".py"):
                download_url = asset["browser_download_url"]
                break

        if not download_url:
            download_url = (
                f"https://raw.githubusercontent.com/Flavio-coding/stream-link/"
                f"{remote_tag}/streamlink.py"
            )
            log.info(f"[UPDATE] Nessun asset .py trovato, uso raw GitHub: {download_url}")
        else:
            log.info(f"[UPDATE] Asset trovato: {download_url}")

        log.info("[UPDATE] Download nuovo streamlink.py…")
        req2 = urllib.request.Request(download_url, headers={"User-Agent": "StreamLink-Updater"})
        with urllib.request.urlopen(req2, timeout=30) as resp2:
            new_content = resp2.read()
        log.info(f"[UPDATE] Scaricati {len(new_content)} bytes")

        tmp_fd, tmp_path = tempfile.mkstemp(suffix=".py", prefix="streamlink_update_")
        try:
            with os.fdopen(tmp_fd, "wb") as tmp_f:
                tmp_f.write(new_content)
            os.chmod(tmp_path, 0o755)
            os.makedirs(os.path.dirname(INSTALL_PATH), exist_ok=True)
            import shutil
            shutil.move(tmp_path, INSTALL_PATH)
            log.info(f"[UPDATE] ✓ Aggiornato a {remote_tag} → {INSTALL_PATH}")
            return True, remote_tag
        except Exception as e:
            log.error(f"[UPDATE] ✗ Errore scrittura file: {e}")
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)
            return False, str(e)

    except urllib.error.URLError as e:
        log.warning(f"[UPDATE] Rete non disponibile: {e.reason}")
        return False, f"Rete: {e.reason}"
    except Exception as e:
        log.error(f"[UPDATE] Errore inatteso: {e}")
        return False, str(e)


# ─── Backend ──────────────────────────────────────────────────────────────────

def run(args, timeout=20):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "Timeout"
    except FileNotFoundError:
        return -2, "", f"Comando non trovato: {args[0]}"
    except Exception as e:
        return -3, "", str(e)

def check_internet():
    log.info("── [1/5] Verifica internet (ping 8.8.8.8)")
    code, _, _ = run(["ping", "-c", "1", "-W", "3", "8.8.8.8"], timeout=6)
    if code == 0:
        log.info("  ✓ Internet disponibile")
        return True, "Internet disponibile"
    log.error("  ✗ Ping fallito — nessun internet")
    return False, "Nessuna connessione internet\nControlla il WiFi o il cavo di rete."

def vpn_is_connected():
    log.info("── [2/5] Controllo stato VPN (protonvpn status)")
    code, out, err = run(["protonvpn", "status"], timeout=10)
    if code == -2:
        log.error("  ✗ protonvpn non trovato nel PATH")
        return False, None, "protonvpn non trovato\nInstalla: sudo apt install proton-vpn-cli"
    if code != 0:
        log.warning(f"  ✗ VPN non connessa (exit={code})")
        return False, None, "VPN non connessa"

    combined = out + err
    has_server = any(
        l.strip().lower().startswith("server:")
        for l in combined.splitlines()
    )
    if not has_server:
        log.warning("  ✗ VPN exit=0 ma nessuna riga 'Server:' nell'output")
        return False, None, "VPN non connessa"

    server_raw = country = ip_addr = ""
    for line in combined.splitlines():
        s   = line.strip()
        low = s.lower()
        if low.startswith("server:"):
            server_raw = s.split(":", 1)[1].strip()
        elif low.startswith("country:"):
            country = s.split(":", 1)[1].strip()
        elif low.startswith("ip:"):
            ip_addr = s.split(":", 1)[1].strip()

    server_display = server_raw
    m = re.search(r'\bin\s+(.+)$', server_raw, re.IGNORECASE)
    if m:
        server_display = m.group(1).strip()

    info = {"server": server_display, "country": country, "ip": ip_addr}
    log.info(f"  ✓ VPN attiva — paese={country} server={server_raw} ip={ip_addr}")
    return True, info, server_display or country or "Connessa"

def connect_vpn():
    log.info("── [3/5] Connessione VPN (protonvpn connect) — timeout=90s")
    code, out, err = run(["protonvpn", "connect"], timeout=90)
    if code == -2:
        return False, "protonvpn non installato\nInstalla: sudo apt install proton-vpn-cli"
    if code == 0:
        log.info("  ✓ protonvpn connect completato (exit=0)")
        return True, "Connesso"
    msg = (err or out or f"exit {code}").splitlines()[0]
    log.error(f"  ✗ protonvpn connect fallito (exit={code}): {msg}")
    return False, f"Connessione fallita\n{msg}"

def extract_link(url):
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) Chrome/120.0.0.0"
        })
        log.info(f"── [4/5] Fetch Telegraph: {url}")
        with urllib.request.urlopen(req, timeout=15) as resp:
            html = resp.read().decode("utf-8", errors="replace")
        log.debug(f"  risposta: {len(html)} bytes")
        matches = re.findall(
            r'href=["\'](https?://(?:www\.)?[a-zA-Z0-9_-]*streaming[a-zA-Z0-9_-]*\.[a-zA-Z]{2,}[^"\']*)["\']',
            html
        )
        if matches:
            log.info(f"  ✓ Link trovato (href): {matches[0]}")
            return matches[0], None
        matches2 = re.findall(
            r'(https?://(?:www\.)?[a-zA-Z0-9_-]*streaming[a-zA-Z0-9_-]*\.[a-zA-Z]{2,}\S*)',
            html
        )
        if matches2:
            log.info(f"  ✓ Link trovato (testo): {matches2[0]}")
            return matches2[0].rstrip('.,)"\''), None
        log.error("  ✗ Nessun link streaming trovato nella pagina")
        return None, "Nessun link trovato nella pagina\nIl sito Telegraph potrebbe essere cambiato."
    except urllib.error.URLError as e:
        log.error(f"  ✗ URLError: {e.reason}")
        return None, f"Errore di rete\n{e.reason}"
    except Exception as e:
        return None, f"Errore\n{e}"

def open_firefox(url):
    log.info(f"── [5/5] Apertura Firefox: {url}")
    for cmd in [["firefox", url], ["flatpak", "run", "org.mozilla.firefox", url]]:
        try:
            log.debug(f"  provo: {cmd[0]}")
            subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            log.info(f"  ✓ Firefox avviato ({cmd[0]})")
            return True, "Firefox avviato"
        except FileNotFoundError:
            continue
    try:
        subprocess.Popen(["xdg-open", url])
        log.info("  ✓ Browser aperto via xdg-open")
        return True, "Browser aperto"
    except Exception as e:
        log.error(f"  ✗ Impossibile aprire browser: {e}")
        return False, str(e)

def send_notification(title, body):
    try:
        subprocess.Popen(
            ["notify-send", "-i", "network-vpn", title, body],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
    except FileNotFoundError:
        pass


# ─── Finestra principale ──────────────────────────────────────────────────────

class MainWindow(Adw.ApplicationWindow):
    _BAR_CHUNK = 0.22
    _BAR_STEP  = 0.016

    def __init__(self, **kw):
        super().__init__(**kw)
        self.set_title("StreamLink")
        self.set_default_size(650, 400)
        self.set_resizable(False)
        self._found_url = None
        self._vpn_info  = None
        self._bar_pos   = 0.0
        self._bar_dir   = 1
        self._bar_src   = None
        self._build()
        self._load_css()
        threading.Thread(target=self._check_updates_bg, daemon=True).start()
        cfg = load_config()
        if cfg["autostart"]:
            GLib.timeout_add(50, lambda: threading.Thread(
                target=self._pipeline, daemon=True).start() or False)

    def _load_css(self):
        css = b"""
        .success     { color: @success_color; }
        .error-color { color: @error_color;   }
        .mono        { font-family: monospace; font-size: 0.95em; }
        .result-panel {
            background-color: alpha(@card_bg_color, 0.6);
            border-radius: 12px;
            padding: 12px 20px;
        }
        .link-btn {
            font-family: monospace;
            font-size: 0.9em;
        }
        """
        p = Gtk.CssProvider()
        p.load_from_data(css)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), p,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

    # ── Barra rimbalzante (Cairo) ─────────────────────────────────────────────

    def _start_bounce(self):
        if self._bar_src:
            GLib.source_remove(self._bar_src)
            self._bar_src = None

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

    def _on_canvas_draw(self, area, cr, width, height):
        RADIUS = height / 2.0
        cr.set_source_rgba(0.5, 0.5, 0.5, 0.25)
        self._rounded_rect(cr, 0, 0, width, height, RADIUS)
        cr.fill()
        x = self._bar_pos * width
        w = self._BAR_CHUNK * width
        cr.set_source_rgb(0.212, 0.518, 0.894)
        self._rounded_rect(cr, x, 0, w, height, RADIUS)
        cr.fill()

    def _rounded_rect(self, cr, x, y, w, h, r):
        cr.new_sub_path()
        cr.arc(x + r,     y + r,     r, math.pi,     3 * math.pi / 2)
        cr.arc(x + w - r, y + r,     r, 3 * math.pi / 2, 0)
        cr.arc(x + w - r, y + h - r, r, 0,            math.pi / 2)
        cr.arc(x + r,     y + h - r, r, math.pi / 2,  math.pi)
        cr.close_path()

    # ── Build UI ──────────────────────────────────────────────────────────────

    def _build(self):
        hb = Adw.HeaderBar()
        hb.set_show_end_title_buttons(True)
        hb.add_css_class("flat")

        pref_btn = Gtk.Button.new_from_icon_name("preferences-system-symbolic")
        pref_btn.add_css_class("flat")
        pref_btn.set_tooltip_text("Preferenze")
        pref_btn.connect("clicked", self._open_prefs)
        hb.pack_end(pref_btn)

        self._stack = Gtk.Stack()
        self._stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        self._stack.set_transition_duration(160)
        self._stack.set_hexpand(True)

        self._stack.add_named(Gtk.Box(), "blank")

        # ── IDLE ──────────────────────────────────────────────────────────────
        idle_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        idle_box.set_valign(Gtk.Align.CENTER)
        idle_box.set_halign(Gtk.Align.CENTER)
        idle_icon = Gtk.Image.new_from_icon_name("network-vpn-symbolic")
        idle_icon.set_pixel_size(64)
        idle_icon.add_css_class("dim-label")
        idle_lbl = Gtk.Label(label="StreamLink")
        idle_lbl.add_css_class("title-1")
        idle_sub = Gtk.Label(label="Premi Avvia per iniziare")
        idle_sub.add_css_class("dim-label")
        self._start_btn_idle = Gtk.Button(label="▶  Avvia")
        self._start_btn_idle.add_css_class("pill")
        self._start_btn_idle.add_css_class("suggested-action")
        self._start_btn_idle.set_size_request(160, 42)
        self._start_btn_idle.set_margin_top(16)
        self._start_btn_idle.connect("clicked", self._on_start)
        idle_box.append(idle_icon)
        idle_box.append(idle_lbl)
        idle_box.append(idle_sub)
        idle_box.append(self._start_btn_idle)
        self._stack.add_named(idle_box, "idle")

        # ── WORKING ───────────────────────────────────────────────────────────
        work_outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        work_outer.set_valign(Gtk.Align.CENTER)
        work_outer.set_halign(Gtk.Align.CENTER)

        self._work_icon = Gtk.Image.new_from_icon_name("content-loading-symbolic")
        self._work_icon.set_pixel_size(64)
        self._work_icon.set_margin_bottom(16)
        work_outer.append(self._work_icon)

        self._work_title = Gtk.Label(label="")
        self._work_title.add_css_class("title-1")
        self._work_title.set_justify(Gtk.Justification.CENTER)
        self._work_title.set_wrap(True)
        self._work_title.set_max_width_chars(30)
        work_outer.append(self._work_title)

        self._work_subtitle = Gtk.Label(label="")
        self._work_subtitle.add_css_class("body")
        self._work_subtitle.add_css_class("dim-label")
        self._work_subtitle.set_justify(Gtk.Justification.CENTER)
        self._work_subtitle.set_wrap(True)
        self._work_subtitle.set_max_width_chars(40)
        self._work_subtitle.set_margin_top(6)
        work_outer.append(self._work_subtitle)

        self._canvas = Gtk.DrawingArea()
        self._canvas.set_size_request(300, 6)
        self._canvas.set_halign(Gtk.Align.CENTER)
        self._canvas.set_margin_top(20)
        self._canvas.set_draw_func(self._on_canvas_draw)
        work_outer.append(self._canvas)

        self._stack.add_named(work_outer, "working")

        # ── ERRORE ────────────────────────────────────────────────────────────
        err_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        err_box.set_valign(Gtk.Align.CENTER)
        err_box.set_halign(Gtk.Align.CENTER)

        err_icon = Gtk.Image.new_from_icon_name("dialog-error-symbolic")
        err_icon.set_pixel_size(64)
        err_icon.add_css_class("error-color")

        self._err_title = Gtk.Label()
        self._err_title.add_css_class("title-2")
        self._err_title.set_justify(Gtk.Justification.CENTER)
        self._err_title.set_wrap(True)
        self._err_title.set_max_width_chars(32)

        self._err_body = Gtk.Label()
        self._err_body.add_css_class("body")
        self._err_body.add_css_class("dim-label")
        self._err_body.set_justify(Gtk.Justification.CENTER)
        self._err_body.set_wrap(True)
        self._err_body.set_max_width_chars(40)

        retry_btn = Gtk.Button(label="↺  Riprova")
        retry_btn.add_css_class("pill")
        retry_btn.add_css_class("suggested-action")
        retry_btn.set_halign(Gtk.Align.CENTER)
        retry_btn.set_margin_top(8)
        retry_btn.connect("clicked", self._on_start)

        err_box.append(err_icon)
        err_box.append(self._err_title)
        err_box.append(self._err_body)
        err_box.append(retry_btn)
        self._stack.add_named(err_box, "error")

        # ── SUCCESSO ──────────────────────────────────────────────────────────
        ok_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        ok_box.set_valign(Gtk.Align.CENTER)
        ok_box.set_halign(Gtk.Align.FILL)
        ok_box.set_margin_start(32)
        ok_box.set_margin_end(32)

        ok_top = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        ok_top.set_halign(Gtk.Align.CENTER)
        ok_top.set_margin_bottom(20)
        ok_icon = Gtk.Image.new_from_icon_name("emblem-ok-symbolic")
        ok_icon.set_pixel_size(64)
        ok_icon.add_css_class("success")
        ok_lbl = Gtk.Label(label="Tutto pronto")
        ok_lbl.add_css_class("title-1")
        ok_sub = Gtk.Label(label="Firefox è stato aperto")
        ok_sub.add_css_class("dim-label")
        ok_top.append(ok_icon)
        ok_top.append(ok_lbl)
        ok_top.append(ok_sub)
        ok_box.append(ok_top)

        info_panel = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=24)
        info_panel.add_css_class("result-panel")
        info_panel.set_halign(Gtk.Align.CENTER)
        info_panel.set_margin_bottom(20)

        srv_col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        srv_hdr = Gtk.Label(label="SERVER")
        srv_hdr.add_css_class("caption")
        srv_hdr.add_css_class("dim-label")
        self._info_server = Gtk.Label(label="—")
        self._info_server.add_css_class("mono")
        self._info_server.set_ellipsize(Pango.EllipsizeMode.END)
        self._info_server.set_max_width_chars(22)
        srv_col.append(srv_hdr)
        srv_col.append(self._info_server)
        info_panel.append(srv_col)

        info_panel.append(Gtk.Separator(orientation=Gtk.Orientation.VERTICAL))

        link_col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        link_hdr = Gtk.Label(label="LINK")
        link_hdr.add_css_class("caption")
        link_hdr.add_css_class("dim-label")
        self._link_btn = Gtk.Button(label="—")
        self._link_btn.add_css_class("flat")
        self._link_btn.add_css_class("link-btn")
        self._link_btn.connect("clicked", lambda _: self._found_url and open_firefox(self._found_url))
        link_col.append(link_hdr)
        link_col.append(self._link_btn)
        info_panel.append(link_col)

        ok_box.append(info_panel)

        riprova_btn = Gtk.Button(label="↺  Riprova")
        riprova_btn.add_css_class("pill")
        riprova_btn.set_halign(Gtk.Align.CENTER)
        riprova_btn.connect("clicked", self._on_full_restart)
        ok_box.append(riprova_btn)

        self._stack.add_named(ok_box, "success")

        # ── Layout ────────────────────────────────────────────────────────────
        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        main_box.set_valign(Gtk.Align.CENTER)
        main_box.set_vexpand(True)
        main_box.append(self._stack)

        self._toast_ov = Adw.ToastOverlay()
        self._toast_ov.set_child(main_box)

        view = Adw.ToolbarView()
        view.add_top_bar(hb)
        view.set_content(self._toast_ov)
        self.set_content(view)

        self._stack.set_visible_child_name("idle")

    # ── Transizione con flash blank ───────────────────────────────────────────

    def _goto(self, name):
        def _blank():
            self._stack.set_visible_child_name("blank")
            GLib.timeout_add(100, _target)
            return False
        def _target():
            self._stack.set_visible_child_name(name)
            return False
        GLib.idle_add(_blank)

    # ── Helpers thread-safe ───────────────────────────────────────────────────

    def _set_working(self, icon_name, title, subtitle=""):
        def _f():
            self._work_icon.set_from_icon_name(icon_name)
            self._work_title.set_label(title)
            self._work_subtitle.set_label(subtitle)
            self._stack.set_visible_child_name("working")
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

    def _show_success(self, url, vpn_info):
        GLib.idle_add(self._stop_bounce)
        def _f():
            self._found_url = url
            server  = vpn_info.get("server", "—") if vpn_info else "—"
            display = url if len(url) <= 32 else url[:30] + "…"
            self._info_server.set_label(server)
            self._link_btn.set_label(display)
            return False
        GLib.idle_add(_f)
        self._goto("success")

    # ── Aggiornamenti ─────────────────────────────────────────────────────────

    def _check_updates_bg(self):
        updated, info = check_for_updates()
        if updated:
            def _notify():
                t = Adw.Toast.new(f"✓ Aggiornamento {info} installato — riavvia l'app")
                t.set_timeout(8)
                self._toast_ov.add_toast(t)
                return False
            GLib.idle_add(_notify)

    # ── Preferenze ────────────────────────────────────────────────────────────

    def _open_prefs(self, _):
        cfg = load_config()
        dlg = Adw.PreferencesDialog()
        dlg.set_title("Preferenze")

        page = Adw.PreferencesPage()
        page.set_title("Generali")
        page.set_icon_name("preferences-system-symbolic")

        grp = Adw.PreferencesGroup()
        grp.set_title("Comportamento")

        sw = Adw.SwitchRow()
        sw.set_title("Avvia automaticamente all'apertura")
        sw.set_subtitle("Esegue la procedura appena si apre l'app")
        sw.set_active(cfg["autostart"])
        sw.connect("notify::active", lambda row, _: save_config(row.get_active()))
        grp.add(sw)
        page.add(grp)
        dlg.add(page)
        dlg.present(self)

    # ── Azioni ────────────────────────────────────────────────────────────────

    def _on_start(self, _):
        self._found_url = None
        self._vpn_info  = None
        self._goto("idle")
        GLib.timeout_add(150, lambda: threading.Thread(
            target=self._pipeline, daemon=True).start() or False)

    def _on_full_restart(self, _):
        self._found_url = None
        self._vpn_info  = None
        def _do():
            log.info("── Riprova: disconnect VPN e restart pipeline")
            run(["protonvpn", "disconnect"], timeout=15)
            self._pipeline()
        threading.Thread(target=_do, daemon=True).start()

    # ── Pipeline ──────────────────────────────────────────────────────────────

    def _wait(self, started_at, minimum=2.0):
        elapsed = time.time() - started_at
        if elapsed < minimum:
            time.sleep(minimum - elapsed)

    def _pipeline(self):
        log.info("════════ Avvio pipeline StreamLink ════════")
        GLib.idle_add(self._start_bounce)

        # 1. Internet
        t = time.time()
        self._set_working("network-wireless-symbolic", "Verifica internet", "Ping 8.8.8.8…")
        ok, msg = check_internet()
        self._wait(t)
        if not ok:
            self._show_error("Nessun internet", msg)
            return

        # 2. Stato VPN
        t = time.time()
        self._set_working("network-vpn-symbolic", "Controllo VPN", "protonvpn status…")
        vpn_ok, vpn_info, _ = vpn_is_connected()
        self._wait(t)
        if vpn_ok:
            self._vpn_info = vpn_info
            self._run_from_link()
            return

        # 3. Connetti VPN
        t = time.time()
        self._set_working("network-vpn-symbolic", "Connessione VPN", "protonvpn connect…")
        ok2, msg2 = connect_vpn()
        self._wait(t)
        if not ok2:
            self._show_error("VPN non connessa", msg2)
            return

        log.info("  attesa 4s stabilizzazione tunnel WireGuard…")
        time.sleep(4)
        vpn_ok2, vpn_info2, _ = vpn_is_connected()
        if not vpn_ok2:
            self._show_error(
                "VPN non verificata",
                "Comando riuscito ma VPN non rilevata.\nRiprova."
            )
            return

        self._vpn_info = vpn_info2
        self._run_from_link()

    def _run_from_link(self):
        # 4. Estrai link
        t = time.time()
        self._set_working("network-receive-symbolic", "Recupero link", "Lettura pagina Telegraph…")
        url, err = extract_link(TELEGRAPH_URL)
        self._wait(t)
        if not url:
            self._show_error("Link non trovato", err or "Pagina non raggiungibile.")
            return
        self._found_url = url

        # 5. Apertura Firefox
        t = time.time()
        self._set_working(
            "web-browser-symbolic",
            "Apertura Firefox",
            url[:60] + ("…" if len(url) > 60 else "")
        )
        ok3, msg3 = open_firefox(url)
        self._wait(t)
        if not ok3:
            self._show_error("Firefox non aperto", msg3)
            return

        log.info("════════ Pipeline completata con successo ════════")
        self._show_success(url, self._vpn_info)
        send_notification("StreamLink — Pronto!", "Firefox aperto con il link aggiornato.")


# ─── App ──────────────────────────────────────────────────────────────────────

class App(Adw.Application):
    def __init__(self):
        super().__init__(
            application_id="it.streamlink.launcher",
            flags=Gio.ApplicationFlags.FLAGS_NONE
        )
        self.connect("activate", lambda a: MainWindow(application=a).present())

if __name__ == "__main__":
    sys.exit(App().run(sys.argv))
