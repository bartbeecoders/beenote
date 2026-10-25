#!/usr/bin/env python3
"""
Dev-only headless test harness for BeeNote (NOT needed to build or run).
Adapted from BeeModel's tools/fakewl.py.

A tiny fake Wayland compositor: it serves just enough of wl_compositor, wl_shm,
xdg_wm_base, wl_seat, wl_data_device_manager and wp_cursor_shape_manager_v1 for
BeeNote, captures every committed frame from the shared-memory buffer, injects
pointer/keyboard input and writes PNG screenshots. Runs completely isolated from
the real desktop (its own socket, a temporary HOME).

usage: tools/fakewl.py [outdir]
"""
import mmap, os, re, select, shutil, socket, struct, subprocess, sys, tempfile, time

GOLDEN = set()
GOLDEN_MODE = ''

OUT = sys.argv[1] if len(sys.argv) > 1 else 'build/shots'
BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'build', 'beenote'))
os.makedirs(OUT, exist_ok=True)

GLOBALS = [(1, 'wl_compositor', 4), (2, 'wl_shm', 1), (3, 'xdg_wm_base', 2),
           (4, 'wl_seat', 5), (5, 'wp_cursor_shape_manager_v1', 1),
           (6, 'wp_fractional_scale_manager_v1', 1), (7, 'wp_viewporter', 1),
           (8, 'zwp_tablet_manager_v2', 1), (9, 'zwp_pointer_constraints_v1', 1),
           (10, 'zwp_relative_pointer_manager_v1', 1), (11, 'wl_data_device_manager', 3)]


def wstr(s):
    b = s.encode() + b'\0'
    return struct.pack('<I', len(b)) + b + b'\0' * (-len(b) % 4)


class Fake:
    def __init__(self, args=(), home=None, welcome=False, cwd=None):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, 'wl')
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.path)
        srv.listen(1)
        self.home = home or tempfile.mkdtemp()  # never the real ~/.config or Omarchy theme
        env = dict(os.environ, WAYLAND_DISPLAY=self.path, HOME=self.home,
                   XDG_RUNTIME_DIR=self.home)
        env.pop('BEENOTE_FONT', None)
        self.env = env
        self.t0 = time.time()
        self.proc = subprocess.Popen([BIN, *args], env=env, cwd=cwd)
        self.first_frame_ms = None
        self.t_input = None                 # input sent, waiting for its frame
        self.latencies = []
        srv.settimeout(5)
        self.c, _ = srv.accept()
        self.buf, self.fds = b'', []
        self.objs = {1: 'wl_display'}
        self.pools, self.buffers = {}, {}
        self.attached = None
        self.frame = None          # (w, h, bytes)
        self.frames = 0
        self.serial = 100
        self.cursor = None
        self.requests = []
        self.size = (1280, 800)

    # ---- wire -------------------------------------------------------------
    def send(self, obj, op, payload=b''):
        self.c.sendall(struct.pack('<II', obj, ((8 + len(payload)) << 16) | op) + payload)

    def find(self, iface):
        return [k for k, v in self.objs.items() if v == iface]

    def pump(self, timeout=0.3, until_frame=False):
        start_frames = self.frames
        end = time.time() + timeout
        while time.time() < end:
            if until_frame and self.frames > start_frames:
                # drain whatever is left quickly
                end = min(end, time.time() + 0.02)
            r, _, _ = select.select([self.c], [], [], max(0, end - time.time()))
            if not r:
                if self.proc.poll() is not None:
                    return
                continue
            try:
                data, anc, _, _ = socket.recv_fds(self.c, 65536, 16)
            except ConnectionResetError:
                data, anc = b'', []
            if not data:
                return
            self.buf += data
            self.fds += anc
            while len(self.buf) >= 8:
                obj, w = struct.unpack_from('<II', self.buf)
                size, op = w >> 16, w & 0xffff
                if len(self.buf) < size:
                    break
                self.handle(obj, op, self.buf[8:size])
                self.buf = self.buf[size:]

    def handle(self, obj, op, p):
        iface = self.objs.get(obj, '?')
        self.requests.append((iface, op))
        u = lambda i: struct.unpack_from('<I', p, i * 4)[0]
        if iface == 'wl_display':
            if op == 1:                                   # get_registry
                self.objs[u(0)] = 'wl_registry'
                for name, itf, ver in GLOBALS:
                    self.send(u(0), 0, struct.pack('<I', name) + wstr(itf) + struct.pack('<I', ver))
            elif op == 0:                                 # sync
                self.send(u(0), 0, struct.pack('<I', 0))
        elif iface == 'wl_registry' and op == 0:          # bind
            name = u(0)
            n = u(1); pad = (n + 3) & ~3
            itf = p[8:8 + n - 1].decode()
            ver, nid = struct.unpack_from('<II', p, 8 + pad)
            self.objs[nid] = itf
            if itf == 'wl_seat':
                self.send(nid, 0, struct.pack('<I', 3))  # pointer | keyboard
        elif iface == 'wl_compositor' and op == 0:
            self.objs[u(0)] = 'wl_surface'
        elif iface == 'xdg_wm_base' and op == 2:
            self.objs[u(0)] = 'xdg_surface'
        elif iface == 'xdg_surface' and op == 1:
            self.objs[u(0)] = 'xdg_toplevel'
        elif iface == 'wl_seat' and op == 0:
            self.objs[u(0)] = 'wl_pointer'
        elif iface == 'wl_seat' and op == 1:
            self.objs[u(0)] = 'wl_keyboard'
        elif iface == 'wp_cursor_shape_manager_v1' and op in (1, 2):
            self.objs[u(0)] = 'wp_cursor_shape_device_v1'
        elif iface == 'zwp_tablet_manager_v2' and op == 0:
            self.objs[u(0)] = 'zwp_tablet_seat_v2'
        elif iface == 'wp_fractional_scale_manager_v1' and op == 1:
            self.objs[u(0)] = 'wp_fractional_scale_v1'
        elif iface == 'wp_viewporter' and op == 1:
            self.objs[u(0)] = 'wp_viewport'
        elif iface == 'wp_viewport' and op == 2:
            self.dest = (u(0), u(1))
        elif iface == 'wp_cursor_shape_device_v1' and op == 1:
            self.cursor = u(1)
        elif iface == 'zwp_pointer_constraints_v1' and op == 1:  # lock_pointer
            self.objs[u(0)] = 'zwp_locked_pointer_v1'
            self.locked = u(0)
            self.send(u(0), 0)                            # locked
        elif iface == 'zwp_locked_pointer_v1' and op == 0:       # destroy
            self.locked = None
        elif iface == 'zwp_relative_pointer_manager_v1' and op == 1:
            self.objs[u(0)] = 'zwp_relative_pointer_v1'
            self.relptr = u(0)
        elif iface == 'zwp_relative_pointer_v1' and op == 0:
            self.relptr = None
        elif iface == 'wl_data_device_manager' and op == 0:   # create_data_source
            self.objs[u(0)] = 'wl_data_source'
            self.sources = getattr(self, 'sources', {}); self.sources[u(0)] = []
        elif iface == 'wl_data_device_manager' and op == 1:   # get_data_device
            self.objs[u(0)] = 'wl_data_device'
            self.ddev = u(0)
        elif iface == 'wl_data_source' and op == 0:           # offer(mime)
            n = u(0)
            self.sources[obj].append(p[4:4 + n - 1].decode())
        elif iface == 'wl_data_source' and op == 1:           # destroy
            self.sources.pop(obj, None)
            if getattr(self, 'selection', None) == obj:
                self.selection = None
        elif iface == 'wl_data_device' and op == 1:           # set_selection(source, serial)
            self.selection = u(0) or None
        elif iface == 'wl_data_offer' and op == 0:            # accept(serial, mime)
            n = u(1)
            self.dnd_accepted = p[8:8 + n - 1].decode() if n else None
        elif iface == 'wl_data_offer' and op == 3:            # finish (a drop taken)
            self.dnd_finished = True
        elif iface == 'wl_data_offer' and op == 1:            # receive(mime, fd)
            fd = self.fds.pop(0)
            os.write(fd, self.offer_text.encode())
            os.close(fd)
        elif iface == 'xdg_toplevel' and op == 2:         # set_title
            n = u(0)
            self.title = p[4:4 + n - 1].decode()
        elif iface == 'xdg_toplevel' and op == 3:         # set_app_id
            n = u(0)
            self.app_id = p[4:4 + n - 1].decode()
        elif iface == 'wl_pointer' and op == 0:          # set_cursor
            self.cursor_hidden = (u(1) == 0)
        elif iface == 'wl_shm' and op == 0:               # create_pool(id, fd, size)
            fd = self.fds.pop(0)
            self.pools[u(0)] = [fd, mmap.mmap(fd, u(1)), u(1)]
            self.objs[u(0)] = 'wl_shm_pool'
        elif iface == 'wl_shm_pool' and op == 2:          # resize
            pool = self.pools[obj]
            pool[1].close()
            pool[1] = mmap.mmap(pool[0], u(0)); pool[2] = u(0)
        elif iface == 'wl_shm_pool' and op == 0:          # create_buffer
            self.buffers[u(0)] = (obj, u(1), u(2), u(3), u(4))
            self.objs[u(0)] = 'wl_buffer'
        elif iface == 'wl_surface' and op == 1:           # attach
            self.attached = u(0)
        elif iface == 'wl_surface' and op == 3:           # frame
            self.objs[u(0)] = 'wl_callback'
            self.pending_cb = u(0)
        elif iface == 'wl_surface' and op == 6:           # commit
            if self.attached is None:
                self.configure()
                return
            pid, off, w, h, stride = self.buffers[self.attached]
            mem = self.pools[pid][1]
            self.frame = (w, h, bytes(mem[off:off + stride * h]))
            self.frames += 1
            if self.first_frame_ms is None:
                self.first_frame_ms = (time.time() - self.t0) * 1000
            if self.t_input is not None:
                self.latencies.append((time.time() - self.t_input) * 1000)
                self.t_input = None
            self.send(self.attached, 0)                   # release
            self.attached = None
            if getattr(self, 'pending_cb', None):
                self.send(self.pending_cb, 0, struct.pack('<I', int(time.time() * 1000) & 0xffffffff))
                self.pending_cb = None

    def configure(self, w=None, h=None, states=()):
        if w: self.size = (w, h)
        tl = self.find('xdg_toplevel')[0]; xs = self.find('xdg_surface')[0]
        arr = b''.join(struct.pack('<I', s) for s in states)
        self.send(tl, 0, struct.pack('<iiI', self.size[0], self.size[1], len(arr)) + arr)
        self.serial += 1
        self.send(xs, 0, struct.pack('<I', self.serial))

    # ---- input --------------------------------------------------------------
    def ptr(self): return self.find('wl_pointer')[0]
    def surf(self): return self.find('wl_surface')[0]

    def enter(self, x, y):
        self.serial += 1
        self.send(self.ptr(), 0, struct.pack('<IIii', self.serial, self.surf(), x * 256, y * 256))
        self.pump(until_frame=True)

    def move(self, x, y, wait=True):
        self.t_input = time.time()
        self.send(self.ptr(), 2, struct.pack('<Iii', 0, x * 256, y * 256))
        if wait: self.pump(until_frame=True)
        self.t_input = None                 # no change -> no frame: not a sample

    def button(self, pressed, btn=0x110):
        self.serial += 1
        self.send(self.ptr(), 3, struct.pack('<IIII', self.serial, int(time.time() * 1000) & 0xffffffff, btn, int(pressed)))
        self.pump(until_frame=True)

    def click(self, x, y, btn=0x110):
        self.move(x, y); self.button(True, btn); self.button(False, btn)

    def drag(self, x0, y0, x1, y1, steps=8, btn=0x110):
        self.move(x0, y0); self.button(True, btn)
        for i in range(1, steps + 1):
            self.move(x0 + (x1 - x0) * i // steps, y0 + (y1 - y0) * i // steps)
        self.button(False, btn)

    def wheel(self, v):
        self.send(self.ptr(), 4, struct.pack('<IIi', 0, 0, v * 256))
        self.pump(until_frame=True)

    def rel(self, dx, dy):
        """relative pointer motion (a locked pointer: play mode)"""
        rp = getattr(self, 'relptr', None)
        if rp:
            fx, fy = int(dx * 256), int(dy * 256)
            self.send(rp, 0, struct.pack('<IIiiii', 0, int(time.time() * 1e6) & 0xffffffff, fx, fy, fx, fy))
            self.pump(0.02)

    def key(self, code):
        kb = self.find('wl_keyboard')[0]
        for st in (1, 0):
            self.serial += 1
            self.send(kb, 3, struct.pack('<IIII', self.serial, 0, code, st))
        self.pump(until_frame=True)

    # ---- a tablet (zwp_tablet_v2): tools on the tablet seat ------------------
    def pen_add(self, eraser=False):
        """A new tool on the tablet seat (a pen, or a pen's eraser end)."""
        seat = self.find('zwp_tablet_seat_v2')[0]
        if not hasattr(self, 'tablet'):
            self.next_srv = 0xff000000
            self.tablet = self.next_srv; self.next_srv += 1
            self.send(seat, 0, struct.pack('<I', self.tablet))          # tablet_added
            self.send(self.tablet, 4)                                    # done
        tool = self.next_srv; self.next_srv += 1
        self.objs[tool] = 'zwp_tablet_tool_v2'
        self.send(seat, 1, struct.pack('<I', tool))                     # tool_added
        self.send(tool, 0, struct.pack('<I', 0x141 if eraser else 0x140))  # type
        self.send(tool, 3, struct.pack('<I', 1))                        # capability: pressure
        self.send(tool, 4)                                               # done
        self.pump(0.05)
        return tool

    def pen_stroke(self, tool, pts, pressure):
        """Into proximity, down at the first point, through the others with this
        pressure (0..1; a list: one a point), up, out. One frame a point."""
        ps = pressure if isinstance(pressure, list) else [pressure] * len(pts)
        frame = lambda: self.send(tool, 18, struct.pack('<I', int(time.time() * 1000) & 0xffffffff))
        self.serial += 1
        self.send(tool, 6, struct.pack('<III', self.serial, self.tablet, self.surf()))  # proximity_in
        for i, ((x, y), p) in enumerate(zip(pts, ps)):
            self.send(tool, 10, struct.pack('<ii', x * 256, y * 256))   # motion
            self.send(tool, 11, struct.pack('<I', int(p * 65535)))      # pressure
            if i == 0:
                self.serial += 1
                self.send(tool, 8, struct.pack('<I', self.serial))      # down
            frame()
            self.pump(until_frame=True)
        self.send(tool, 9); frame()                                      # up
        self.send(tool, 7); frame()                                      # proximity_out
        self.pump(0.2)

    def mods(self, depressed):
        kb = self.find('wl_keyboard')[0]
        self.serial += 1
        self.send(kb, 4, struct.pack('<IIIII', self.serial, depressed, 0, 0, 0))

    def clipboard(self):
        """Paste as another program would: the app's selection, through a pipe."""
        src = getattr(self, 'selection', None)
        if not src:
            return None
        r, w = os.pipe()
        mime = wstr('text/plain;charset=utf-8')
        msg = struct.pack('<II', src, ((8 + len(mime)) << 16) | 1) + mime
        socket.send_fds(self.c, [msg], [w])
        os.close(w)
        os.set_blocking(r, False)
        out, end = b'', time.time() + 2
        while time.time() < end:
            self.pump(0.05)
            try:
                chunk = os.read(r, 65536)
            except BlockingIOError:
                continue
            if not chunk:
                break
            out += chunk
        os.close(r)
        return out.decode(errors='replace')

    def set_clipboard(self, text):
        """Another program copies text: an offer becomes the selection."""
        self.offer_text = text
        self.n_offers = getattr(self, 'n_offers', 0) + 1
        oid = 0xff100000 + self.n_offers
        self.objs[oid] = 'wl_data_offer'
        old = getattr(self, 'selection', None)
        if old:                                    # the app's source: cancelled
            self.send(old, 2)
            self.selection = None
        self.send(self.ddev, 0, struct.pack('<I', oid))            # data_offer
        self.send(oid, 0, wstr('text/plain;charset=utf-8'))        # offer
        self.send(self.ddev, 5, struct.pack('<I', oid))            # selection
        self.pump(0.1)

    def drop_files(self, paths, x=600, y=300):
        """Files dragged from a file manager and dropped on the window
        (text/uri-list, as file:// URIs with %XX escapes)."""
        from urllib.parse import quote
        self.offer_text = ''.join('file://' + quote(os.path.abspath(p)) + '\r\n' for p in paths)
        self.n_offers = getattr(self, 'n_offers', 0) + 1
        oid = 0xff100000 + self.n_offers
        self.objs[oid] = 'wl_data_offer'
        self.dnd_accepted, self.dnd_finished = None, False
        self.send(self.ddev, 0, struct.pack('<I', oid))            # data_offer
        self.send(oid, 0, wstr('text/uri-list'))                   # offer
        self.send(oid, 0, wstr('text/plain;charset=utf-8'))
        self.serial += 1
        self.send(self.ddev, 1, struct.pack('<IIiiI', self.serial, self.surf(),
                                            int(x * 256), int(y * 256), oid))  # enter
        self.send(self.ddev, 3, struct.pack('<Iii', 0, int(x * 256), int(y * 256)))  # motion
        self.pump(0.1)
        self.send(self.ddev, 4)                                    # drop
        self.pump(0.5)

    def keymap(self, path):
        data = open(path, 'rb').read() + b'\0'
        fd = os.memfd_create('keymap')
        os.write(fd, data)
        kb = self.find('wl_keyboard')[0]
        msg = struct.pack('<IIII', kb, (16 << 16) | 0, 1, len(data))
        socket.send_fds(self.c, [msg], [fd])
        os.close(fd)
        self.pump(0.2)

    def repeat_info(self, rate, delay):
        self.send(self.find('wl_keyboard')[0], 5, struct.pack('<ii', rate, delay))

    def keyev(self, code, down):
        self.serial += 1
        self.send(self.find('wl_keyboard')[0], 3, struct.pack('<IIII', self.serial, 0, code, int(down)))

    US = {**{c: k for k, c in enumerate('1234567890', 2)}, **{c: k for k, c in enumerate('qwertyuiop', 16)},
          **{c: k for k, c in enumerate('asdfghjkl', 30)}, **{c: k for k, c in enumerate('zxcvbnm', 44)},
          '.': 52, '-': 12, ' ': 57, '/': 53, '=': 13, ',': 51, ';': 39, "'": 40, '[': 26, ']': 27, '\\': 43}
    US_SHIFT = {'_': 12, '(': 10, ')': 11, '"': 40, '+': 13, '{': 26, '}': 27, '*': 9, '<': 51, '>': 52,
                '#': 4, '%': 6, '!': 2, ':': 39}

    def type(self, text):
        for ch in text:
            shift = ch in self.US_SHIFT or ch.isupper()
            code = self.US_SHIFT[ch] if ch in self.US_SHIFT else self.US[ch.lower()]
            if shift: self.mods(1)
            self.keyev(code, 1); self.keyev(code, 0)
            if shift: self.mods(0)
        self.pump(until_frame=True)

    def scale(self, s120):
        self.send(self.find('wp_fractional_scale_v1')[0], 0, struct.pack('<I', s120))
        self.pump(0.5, until_frame=True)

    def image(self):
        from PIL import Image
        w, h, data = self.frame
        return Image.frombuffer('RGBX', (w, h), data, 'raw', 'BGRX', 0, 1).convert('RGB')

    def shot(self, name):
        w, h, _ = self.frame
        img = self.image()
        path = os.path.join(OUT, name)
        img.save(path)
        print(f'  shot {path} ({w}x{h}, frame #{self.frames}, cursor shape {self.cursor})')

    def rss_anon_kb(self):
        for line in open(f'/proc/{self.proc.pid}/status'):
            if line.startswith('RssAnon:'):
                return int(line.split()[1])


FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def px(f, x, y):
    w, h, data = f.frame
    b, g, r, _ = data[(y * w + x) * 4:(y * w + x) * 4 + 4]
    return (r << 16) | (g << 8) | b




# =============================================================================
#  BeeNote's checks
# =============================================================================
CTRL, SHIFT, ALT = 4, 1, 8
NORD = {'background': '#2e3440', 'foreground': '#d8dee9', 'accent': '#81a1c1',
        'selection': '#434c5e', 'muted': '#4c566a', 'dark_background': '#222730',
        'lighter_background': '#3b4252', 'dark_foreground': '#667080',
        'light_foreground': '#adb5c4', 'red': '#bf616a'}


def theme(home, colours):
    d = os.path.join(home, '.local/state/omarchy/current/theme')
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, 'colors.toml'), 'w') as fh:
        fh.write('mode = "dark"\n\n' + ''.join(f'{k} = "{v}"\n' for k, v in colours.items()))


def combo(f, mods, code):
    f.mods(mods)
    f.key(code)
    f.mods(0)
    f.pump(0.05)


def main():
    home = tempfile.mkdtemp()
    theme(home, NORD)
    doc = os.path.join(home, 'notes.txt')
    with open(doc, 'w') as fh:
        fh.write('Hello BeeNote\nsecond line\n\tindented\n')

    f = Fake(args=[doc], home=home)
    f.pump(1.5, until_frame=True)
    check(f.frame is not None, 'a first frame')
    check(f.first_frame_ms is not None and f.first_frame_ms < 500,
          f'first frame in {f.first_frame_ms and round(f.first_frame_ms)} ms')
    check(getattr(f, 'app_id', None) == 'beenote', f'app_id {getattr(f, "app_id", None)!r}')
    check(getattr(f, 'title', '') == 'notes.txt — BeeNote', f'title {getattr(f, "title", None)!r}')
    f.shot('01_open.png')
    check(px(f, 640, 600) == 0x2e3440, f'the background is the Omarchy theme\'s: {px(f, 640, 600):06x}')

    f.keymap('tests/keymaps/us.xkb')
    f.enter(400, 300)

    # ---- typing and saving --------------------------------------------------
    combo(f, CTRL, 107)                     # Ctrl+End
    f.type('typed here')
    check(getattr(f, 'title', '').startswith('● '), f'modified title {f.title!r}')
    combo(f, CTRL, 31)                      # Ctrl+S
    text = open(doc).read()
    check(text == 'Hello BeeNote\nsecond line\n\tindented\ntyped here', f'saved: {text!r}')
    check(f.title == 'notes.txt — BeeNote', f'saved title {f.title!r}')
    f.shot('02_typed.png')

    # ---- undo / redo ------------------------------------------------------------
    combo(f, CTRL, 44)                      # Ctrl+Z: the typing, in one step
    combo(f, CTRL, 31)
    check(open(doc).read() == 'Hello BeeNote\nsecond line\n\tindented\n', 'undo took the typing back')
    combo(f, CTRL | SHIFT, 44)              # Ctrl+Shift+Z
    combo(f, CTRL, 31)
    check(open(doc).read().endswith('typed here'), 'redo put it back')

    # ---- menus ----------------------------------------------------------------
    f.key(68)                               # F10: File
    f.shot('03_menu_file.png')
    f.key(106)                              # Right: Edit
    f.shot('04_menu_edit.png')
    f.key(1)                                # Esc
    combo(f, ALT, 47)                       # Alt+V: View
    f.shot('05_menu_view.png')
    f.key(108); f.key(108); f.key(108)      # Down x3 -> Actual Size? (Zoom In first)
    f.key(1)

    # ---- mouse: a double click selects a word, Ctrl+C copies it --------------
    f.move(80, 50)
    f.button(True); f.button(False)
    f.button(True); f.button(False)
    combo(f, CTRL, 46)                      # Ctrl+C
    got = f.clipboard()
    check(got == 'Hello', f'double click + copy -> clipboard {got!r}')
    f.shot('06_word_selected.png')

    # ---- another program's text is pasted -----------------------------------------
    f.set_clipboard('from outside\r\n')
    combo(f, CTRL, 107)                     # Ctrl+End
    f.key(28)                               # Enter
    combo(f, CTRL, 47)                      # Ctrl+V
    combo(f, CTRL, 31)
    check(open(doc).read().endswith('typed here\nfrom outside\n'), f'pasted: {open(doc).read()[-30:]!r}')

    # ---- find as you type ----------------------------------------------------
    combo(f, CTRL, 33)                      # Ctrl+F
    f.type('SECOND')
    f.shot('07_find.png')
    f.key(1)                                # Esc: the match stays selected
    combo(f, CTRL, 46)
    got = f.clipboard()
    check(got == 'second', f'find selected {got!r}')

    # ---- a line cut and pasted, drag selection -------------------------------
    combo(f, CTRL, 102)                     # Ctrl+Home
    combo(f, CTRL, 45)                      # Ctrl+X: the line
    combo(f, CTRL, 31)
    check(open(doc).read().startswith('second line\n'), f'cut a line: {open(doc).read()[:20]!r}')
    combo(f, CTRL, 44)                      # undo

    # ---- zoom -------------------------------------------------------------------
    combo(f, CTRL, 13); combo(f, CTRL, 13)
    f.shot('08_zoomed.png')
    combo(f, CTRL, 11)                      # Ctrl+0

    # ---- live theme switch ---------------------------------------------------
    light = dict(NORD, background='#eff1f5', foreground='#4c4f69', dark_background='#e6e9ef',
                 lighter_background='#ccd0da', selection='#acb0be', accent='#1e66f5')
    theme(home, light)
    f.pump(2.0)
    f.move(400, 300)
    check(px(f, 640, 600) == 0xeff1f5, f'theme switched live: {px(f, 640, 600):06x}')
    f.shot('09_light_theme.png')
    theme(home, NORD)
    f.pump(2.0)
    f.move(400, 310)

    # ---- help and about --------------------------------------------------------
    f.key(59)                               # F1
    f.shot('10_help.png')
    f.key(1)

    # ---- unsaved changes: the dialog ------------------------------------------------
    f.type('x')
    combo(f, CTRL, 16)                      # Ctrl+Q
    f.shot('11_ask_save.png')
    check(f.proc.poll() is None, 'Ctrl+Q with changes asks first')
    f.key(1)                                # Esc: Cancel
    f.pump(0.3)
    check(f.proc.poll() is None, 'Esc cancels quitting')
    combo(f, CTRL, 16)
    f.type('d')                             # Don't Save
    f.pump(1.0)
    check(f.proc.poll() == 0, f'"Don\'t Save" quits (exit {f.proc.poll()})')
    check(not open(doc).read().endswith('x'), 'and did not save')


def files_and_mouse():
    home = tempfile.mkdtemp()
    theme(home, NORD)
    os.makedirs(os.path.join(home, 'docs'))
    with open(os.path.join(home, 'docs', 'readme.md'), 'w') as fh:
        fh.write('alpha beta gamma\ndelta epsilon\nzeta eta theta\n')
    big = os.path.join(home, 'big.txt')
    with open(big, 'w') as fh:
        fh.write(''.join(f'line {i}\n' for i in range(1, 5001)))

    f = Fake(args=[], home=home)            # untitled
    f.pump(1.5, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(400, 300)
    check(f.title == 'Untitled \u2014 BeeNote', f'untitled title {f.title!r}')

    # ---- Save as: the prompt, a typed path ---------------------------------------
    f.type('draft')
    combo(f, CTRL, 31)                      # Ctrl+S on an untitled document: Save as
    f.shot('20_save_as.png')
    combo(f, CTRL, 14)                      # Ctrl+Backspace: clear the field
    draft = os.path.join(home, 'draft.txt')
    f.type(draft)
    f.key(28)
    f.pump(0.2)
    check(os.path.exists(draft) and open(draft).read() == 'draft', 'saved as draft.txt')
    check(f.title == 'draft.txt \u2014 BeeNote', f'title {f.title!r}')

    # ---- the Open dialog ----------------------------------------------------------
    combo(f, CTRL, 24)                      # Ctrl+O: the folder of draft.txt
    f.shot('21_open_dialog.png')
    f.key(1)                                # Esc: cancelled, nothing changes
    check(f.title == 'draft.txt \u2014 BeeNote', f'Esc keeps the document: {f.title!r}')
    combo(f, CTRL, 24)
    f.type('do')                            # the filter: only docs/
    f.shot('21b_open_filtered.png')
    f.key(28)                               # Enter: into docs/
    f.type('readme')
    f.key(28)
    check(f.title == 'readme.md \u2014 BeeNote', f'filter + Enter opened: {f.title!r}')
    combo(f, CTRL, 24)                      # a typed path: open already, its tab
    f.mods(1); f.keyev(41, 1); f.keyev(41, 0); f.mods(0)   # Shift+` = ~
    f.type('/draft.txt')
    f.key(28)
    check(f.title == 'draft.txt \u2014 BeeNote', f'a typed ~/ path opened: {f.title!r}')

    # the mouse: a double click on a folder, then on a file (dialog 760x560, centred)
    combo(f, CTRL, 24)                      # the home folder: .., docs/, big.txt, draft.txt
    f.shot('21c_open_up.png')
    row = lambda i: 214 + 28 * i + 14
    f.move(400, row(1)); f.button(True); f.button(False); f.button(True); f.button(False)
    f.move(400, row(1)); f.button(True); f.button(False); f.button(True); f.button(False)
    check(f.title == 'readme.md \u2014 BeeNote', f'double clicks opened {f.title!r}')

    # ---- drag selection, triple click, the context menu ----------------------------
    # (two tabs are open: the text starts below the tab bar, at y = 62)
    f.drag(58 + 6 * 10, 62 + 12, 58 + 6 * 10, 62 + 25 + 12)   # 'beta gamma\ndelta '
    combo(f, CTRL, 46)
    got = f.clipboard()
    check(got.startswith('beta gamma\n') and got.startswith('beta gamma\ndelt'), f'drag selected {got!r}')
    f.move(100, 62 + 50 + 12)
    for _ in range(3):
        f.button(True); f.button(False)
    combo(f, CTRL, 46)
    got = f.clipboard()
    check(got == 'zeta eta theta\n', f'triple click selected {got!r}')
    f.click(300, 120, 0x111)                # right click: the Edit menu there
    f.shot('22_context_menu.png')
    f.key(1)

    # ---- a dropped file; go to line; the wheel -----------------------------------------
    f.drop_files([big])
    check(f.title == 'big.txt \u2014 BeeNote', f'dropped file opened: {f.title!r}')
    combo(f, CTRL, 34)                      # Ctrl+G
    f.type('4000')
    f.key(28)
    combo(f, CTRL, 46)                      # (no selection: the line)
    got = f.clipboard()
    check(got == 'line 4000\n', f'go to line 4000: {got!r}')
    f.shot('23_goto.png')
    f.move(400, 300)
    for _ in range(5):
        f.wheel(10)
    f.shot('24_wheel.png')

    # ---- typing speed in a 5000-line file -------------------------------------------
    f.latencies = []
    for ch in 'abcdefghij':
        f.t_input = time.time()
        f.type(ch)
    lat = sum(f.latencies) / max(1, len(f.latencies))
    check(lat < 30, f'typing in a 5000-line file: {lat:.1f} ms a frame')
    combo(f, CTRL, 44)

    # ---- HiDPI: fractional scale 1.5 -------------------------------------------------
    f.scale(180)
    f.configure(1280, 800)
    f.pump(0.5, until_frame=True)
    w, h, _ = f.frame
    check((w, h) == (1920, 1200), f'scale 1.5: buffer {w}x{h}')
    f.shot('25_scale150.png')

    combo(f, CTRL, 16)                      # (typed and undone: still modified)
    check(f.proc.poll() is None, 'Ctrl+Q asks about the undone typing')
    f.type('d')
    f.pump(0.5)
    check(f.proc.poll() == 0, f'quits (exit {f.proc.poll()})')


def config_live():
    """beenote.conf changes (an Omarchy font switch, a size) apply live."""
    home = tempfile.mkdtemp()
    theme(home, NORD)
    conf = os.path.join(home, '.config/beenote/beenote.conf')
    os.makedirs(os.path.dirname(conf))
    with open(conf, 'w') as fh:
        fh.write('font = /usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf\nsize = 12\n')
    doc = os.path.join(home, 'a.txt')
    with open(doc, 'w') as fh:
        fh.write('The quick brown fox jumps over the lazy dog\n')
    f = Fake(args=[doc], home=home)
    f.pump(1.5, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(400, 300)
    before = f.image().crop((0, 32, 700, 60)).tobytes()
    with open(conf, 'w') as fh:
        fh.write('font = /usr/share/fonts/liberation/LiberationMono-Regular.ttf\nsize = 12\n')
    f.pump(2.0)
    f.move(400, 310)
    after = f.image().crop((0, 32, 700, 60)).tobytes()
    check(before != after, 'a new font in beenote.conf shows without a restart')
    f.shot('30_font_liberation.png')
    with open(conf, 'w') as fh:
        fh.write('font = /usr/share/fonts/liberation/LiberationMono-Regular.ttf\nsize = 18\n')
    f.pump(2.0)
    f.move(400, 300)
    f.shot('31_size18.png')
    w, h, data = f.frame
    # the first line's text reaches further right at 18 pt than at 12 pt
    def text_right(img):
        px_ = img.load()
        right = 0
        for x in range(60, 1000):
            for y in range(36, 70):
                if sum(px_[x, y]) > 450:
                    right = x
        return right
    check(text_right(f.image()) > 600, f'size 18 is bigger: text to x={text_right(f.image())}')
    f.proc.kill()


def recent_files():
    """The File menu's recent files, kept in ~/.local/state/beenote/recent."""
    home = tempfile.mkdtemp()
    theme(home, NORD)
    os.makedirs(os.path.join(home, 'docs'))
    paths = [os.path.join(home, 'docs' if i % 2 else '', f'f{i:02}.txt') for i in range(12)]
    for i, p in enumerate(paths):
        with open(p, 'w') as fh:
            fh.write(f'file {i}\n')
    listf = os.path.join(home, '.local/state/beenote/recent')
    saved = lambda: open(listf).read().splitlines() if os.path.exists(listf) else []

    f = Fake(args=[paths[0]], home=home)
    f.pump(1.5, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(400, 300)
    check(saved() == [paths[0]], f'the opened file is listed: {saved()!r}')
    f.drop_files([paths[1]])
    f.drop_files([paths[2]])
    check(saved() == [paths[2], paths[1], paths[0]], f'newest first: {saved()!r}')
    f.key(68)                               # F10: File, with the three
    f.shot('40_recent_menu.png')
    f.type('2')                             # its mnemonic: the second
    check(f.title == 'f01.txt \u2014 BeeNote', f'2 opened the second: {f.title!r}')
    check(saved() == [paths[1], paths[2], paths[0]], f'and moved it up: {saved()!r}')

    for p in paths[3:]:                     # twelve files: the ten newest stay
        f.drop_files([p])
    want = [paths[1], paths[2], paths[0]]
    for p in paths[3:]:
        want = ([p] + want)[:10]
    check(saved() == want, f'ten at most: {len(saved())} {saved()[:2]!r}')
    f.key(68)
    f.shot('41_recent_full.png')
    f.type('0')                             # the tenth: "10", its 0 underlined
    check(f.title == f'{os.path.basename(want[9])} \u2014 BeeNote', f'0 opened the tenth: {f.title!r}')

    want = [want[9]] + want[:9]
    gone = want[5]
    os.remove(gone)                         # a file that went away
    f.key(68)
    f.type('6')                             # (open in a tab: that tab)
    check(f.title == f'{os.path.basename(gone)} \u2014 BeeNote', f'6 showed its tab: {f.title!r}')
    combo(f, CTRL, 17)                      # Ctrl+W: closed, now it is not open
    f.key(68)
    f.type('1')                             # (it went to the top)
    check(gone not in saved() and len(saved()) == 9, f'a missing file leaves the list: {len(saved())}')

    combo(f, CTRL, 31)                      # saving lists the file too
    check(saved()[0] == gone, f'saving it listed it again: {saved()[0]!r}')

    f.key(68)
    f.type('c')                             # Clear Recent Files
    check(saved() == [], f'cleared: {saved()!r}')
    f.key(68)
    f.shot('42_recent_cleared.png')
    f.key(1)
    f.proc.kill()

    g = Fake(args=['./docs/f01.txt'], home=home, cwd=home)   # a relative name
    g.pump(1.5, until_frame=True)
    check(saved() == [paths[1]], f'a relative name is listed absolute: {saved()!r}')
    g.proc.kill()


def tabs():
    """Several documents at once, a tab each."""
    home = tempfile.mkdtemp()
    theme(home, NORD)
    a, b, c = (os.path.join(home, n) for n in ('a.txt', 'b.txt', 'c.txt'))
    for p, t in ((a, 'alpha\n'), (b, 'bravo\n'), (c, ''.join(f'c{i}\n' for i in range(300)))):
        with open(p, 'w') as fh:
            fh.write(t)
    f = Fake(args=[a, b], home=home)        # two files: two tabs, the first shown
    f.pump(1.5, until_frame=True)
    f.keymap('tests/keymaps/us.xkb')
    f.enter(400, 300)
    check(f.title == 'a.txt \u2014 BeeNote', f'the first file is shown: {f.title!r}')
    check(px(f, 640, 45) == 0x222730, f'the tab bar is shown: {px(f, 640, 45):06x}')
    f.shot('50_tabs.png')
    combo(f, CTRL, 15)                      # Ctrl+Tab
    check(f.title == 'b.txt \u2014 BeeNote', f'Ctrl+Tab: {f.title!r}')
    combo(f, CTRL, 15)                      # (wraps around)
    check(f.title == 'a.txt \u2014 BeeNote', f'Ctrl+Tab wraps: {f.title!r}')
    combo(f, CTRL | SHIFT, 15)
    check(f.title == 'b.txt \u2014 BeeNote', f'Ctrl+Shift+Tab: {f.title!r}')

    # each tab keeps its own text, cursor and undo history
    combo(f, CTRL, 107)
    f.type('B')
    combo(f, CTRL, 104)                     # Ctrl+PgUp: a.txt
    combo(f, CTRL, 107)
    f.type('A1 A2')
    combo(f, CTRL, 109)                     # Ctrl+PgDn: b.txt
    combo(f, CTRL, 44)                      # undo here: only b's typing
    combo(f, CTRL, 31)
    check(open(b).read() == 'bravo\n', f'b undone and saved: {open(b).read()!r}')
    combo(f, CTRL | SHIFT, 44)              # redo
    f.click(100, 46)                        # the first tab, clicked
    check(f.title.startswith('\u25cf a.txt'), f'a click picks a tab: {f.title!r}')
    combo(f, CTRL, 31)
    check(open(a).read() == 'alpha\nA1 A2', f'a kept its typing: {open(a).read()!r}')
    f.shot('51_tab_unsaved.png')

    # the Open dialog and dropped files open new tabs; scrolling stays per tab
    f.drop_files([c])
    check(f.title == 'c.txt \u2014 BeeNote', f'a dropped file, a new tab: {f.title!r}')
    combo(f, CTRL, 107)                     # Ctrl+End: scrolled to the bottom
    f.key(103)                              # Up: the last line, c299
    combo(f, ALT, 2)                        # Alt+1: the first tab
    check(f.title == 'a.txt \u2014 BeeNote', f'Alt+1: {f.title!r}')
    combo(f, ALT, 10)                       # Alt+9: the last
    check(f.title == 'c.txt \u2014 BeeNote', f'Alt+9: {f.title!r}')
    combo(f, CTRL, 46)                      # (no selection: the cursor's line)
    check(f.clipboard() == 'c299\n', f'the cursor stayed at the end: {f.clipboard()!r}')
    f.shot('52_three_tabs.png')
    f.drop_files([a])                       # open already: its tab
    check(f.title == 'a.txt \u2014 BeeNote', f'an open file is not opened twice: {f.title!r}')

    # Ctrl+N: a new tab; Ctrl+W asks about changes
    combo(f, CTRL, 49)
    check(f.title == 'Untitled \u2014 BeeNote', f'Ctrl+N: {f.title!r}')
    f.type('scratch')
    f.shot('53_new_tab.png')
    combo(f, CTRL, 17)                      # Ctrl+W
    f.shot('54_close_asks.png')
    f.key(1)                                # Esc: Cancel, the tab stays
    check(f.title == '\u25cf Untitled \u2014 BeeNote', f'cancelled: {f.title!r}')
    combo(f, CTRL, 17)
    f.type('d')                             # Don't Save: closed, the one before shows
    check(f.title == 'c.txt \u2014 BeeNote', f'closed: {f.title!r}')

    # the mouse: the x on a tab closes it, the others stay where they were
    f.click(220 * 1 + 220 - 16, 46)         # b.txt's x (tabs are 220 px; redone: unsaved)
    check(f.title == '\u25cf b.txt \u2014 BeeNote', f'it shows b.txt while it asks: {f.title!r}')
    f.type('d')
    check(f.title == 'c.txt \u2014 BeeNote', f'closing another tab keeps this one: {f.title!r}')
    combo(f, CTRL, 15)
    check(f.title == 'a.txt \u2014 BeeNote', f'b.txt was closed: {f.title!r}')
    f.click(220 + 100, 46, 0x112)           # middle click: c.txt
    check(f.title == 'a.txt \u2014 BeeNote', f'middle click closed c.txt: {f.title!r}')
    check(px(f, 640, 45) == 0x2e3440, f'one tab left: no tab bar: {px(f, 640, 45):06x}')
    f.shot('55_one_tab.png')

    # quitting asks for each tab with changes
    combo(f, CTRL, 49)
    f.type('one')
    combo(f, CTRL, 49)
    f.type('two')
    combo(f, CTRL, 16)                      # Ctrl+Q
    check(f.title == '\u25cf Untitled \u2014 BeeNote' and f.proc.poll() is None, 'Ctrl+Q asks')
    f.type('d')                             # the first: Don't Save
    f.pump(0.3)
    check(f.proc.poll() is None, 'then asks about the second')
    f.type('d')
    f.pump(1.0)
    check(f.proc.poll() == 0, f'and quits (exit {f.proc.poll()})')


if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        pass
    files_and_mouse()
    config_live()
    recent_files()
    tabs()
    print()
    print('FAILED: %d' % len(FAILS) if FAILS else 'all ok')
    sys.exit(1 if FAILS else 0)
