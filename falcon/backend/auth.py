"""FALCON auth: akun operator, sesi cookie, pembatasan percobaan login.

Prinsip:
  - Sandi TIDAK disimpan polos: scrypt + garam acak per akun (stdlib, tanpa dependensi).
  - Berkas akun di luar repo (FALCON_USERS_FILE, default ~/.falcon/users.json, mode 600).
  - Sesi = token acak 256-bit di memori; cookie HttpOnly + SameSite=Strict.
  - Sandi acak dibuat SEKALI oleh `python -m falcon.backend.auth add <user> <role>` dan
    TIDAK pernah diputar otomatis.
"""
import base64, hashlib, hmac, json, os, secrets, sys, time

USERS_FILE = os.environ.get("FALCON_USERS_FILE", os.path.expanduser("~/.falcon/users.json"))
SESSION_TTL = int(os.environ.get("FALCON_SESSION_TTL", 12 * 3600))
COOKIE = "falcon_session"
ROLES = ("operator", "viewer")

# scrypt: n=2**14 cukup kuat dan tetap ringan untuk RPi/lab
_N, _R, _P, _DK = 2 ** 14, 8, 1, 32

_sessions = {}          # token -> {"user","role","exp"}
_fail = {}              # ip -> [timestamp gagal, ...]
MAX_FAIL, FAIL_WINDOW, LOCK_SECONDS = 5, 300, 300


def _hash(password: str, salt: bytes) -> str:
    h = hashlib.scrypt(password.encode(), salt=salt, n=_N, r=_R, p=_P, dklen=_DK)
    return base64.b64encode(h).decode()


def _load() -> dict:
    try:
        with open(USERS_FILE) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def _save(users: dict):
    os.makedirs(os.path.dirname(USERS_FILE), exist_ok=True)
    tmp = USERS_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(users, f, indent=2)
    os.replace(tmp, USERS_FILE)
    os.chmod(USERS_FILE, 0o600)


def add_user(username: str, role: str, password: str | None = None) -> str:
    """Buat akun baru. Tolak jika sudah ada (sandi tidak ditimpa diam-diam)."""
    if role not in ROLES:
        raise ValueError(f"role harus salah satu dari {ROLES}")
    users = _load()
    if username in users:
        raise ValueError(f"akun '{username}' sudah ada; sandi tidak diubah")
    password = password or secrets.token_urlsafe(18)
    salt = secrets.token_bytes(16)
    users[username] = {"role": role, "salt": base64.b64encode(salt).decode(),
                       "hash": _hash(password, salt), "created": int(time.time())}
    _save(users)
    return password


def has_users() -> bool:
    return bool(_load())


def verify(username: str, password: str):
    """Kembalikan role jika benar, None jika salah. Waktu konstan terhadap akun yang tidak ada."""
    users = _load()
    u = users.get(username)
    salt = base64.b64decode(u["salt"]) if u else b"\0" * 16
    got = _hash(password, salt)
    want = u["hash"] if u else "x" * len(got)
    ok = hmac.compare_digest(got, want) and u is not None
    return u["role"] if ok else None


def locked(ip: str) -> int:
    """Sisa detik terkunci (0 = boleh coba)."""
    now = time.time()
    fails = [t for t in _fail.get(ip, []) if now - t < FAIL_WINDOW]
    _fail[ip] = fails
    if len(fails) >= MAX_FAIL:
        return max(1, int(LOCK_SECONDS - (now - fails[-1])))
    return 0


def note_fail(ip: str):
    _fail.setdefault(ip, []).append(time.time())


def note_ok(ip: str):
    _fail.pop(ip, None)


def new_session(username: str, role: str) -> str:
    tok = secrets.token_urlsafe(32)
    _sessions[tok] = {"user": username, "role": role, "exp": time.time() + SESSION_TTL}
    return tok


def get_session(token: str | None):
    if not token:
        return None
    s = _sessions.get(token)
    if not s:
        return None
    if s["exp"] < time.time():
        _sessions.pop(token, None)
        return None
    return s


def end_session(token: str | None):
    if token:
        _sessions.pop(token, None)


def _cli(argv):
    if len(argv) >= 3 and argv[0] == "add":
        pw = add_user(argv[1], argv[2])
        print(f"akun dibuat: {argv[1]} ({argv[2]})\nsandi (SIMPAN di password manager, tidak ditampilkan lagi): {pw}")
    elif argv[:1] == ["list"]:
        for k, v in _load().items():
            print(k, v["role"])
    else:
        print("pakai: python -m falcon.backend.auth add <user> <operator|viewer> | list")


if __name__ == "__main__":
    _cli(sys.argv[1:])
