#!/usr/bin/env python3
"""fm-disk-lens.py - local browser view of what holds this Mac's disk, CPU,
RAM, and firstmate's own resources, with guarded cleanup actions.

bin/fm-disk-lens.sh is the supported launcher: it picks the port, writes the
per-launch token, finds the agent process to outlive, and opens the browser.

Usage:
  fm-disk-lens.py --home <FM_HOME> --token-file <file> [--port <n>]
                  [--bind 127.0.0.1] [--watch-pid <pid>] [--idle-minutes <n>]
                  [--url-file <file>]
  fm-disk-lens.py --home <FM_HOME> --scan-json [--tabs disk,firstmate]
                  [--no-du] [--top <n>] [--min-mb <n>]

--scan-json runs the page's scanner once, read-only, and prints JSON: volume
total/used/free, per tab/group totals, the --top largest items (kind, path,
size in bytes, the action the page would offer, git and pool details), and
scanner errors. Without --no-du it runs du on every item (minutes on a full
home); --no-du lists items with docker sizes only.

Tabs: Disk, Firstmate, CPU, RAM.
Every action is a click in the page followed by an in-page confirmation; the
server never deletes, frees, or kills anything on its own.

Safety rules this server enforces (the page only displays them):
  - Binds 127.0.0.1 only; any other --bind exits 2 before listening.
  - Every /api request needs the X-Disk-Lens-Token header equal to the token
    file's content, and the page itself needs ?token=; a request whose Host or
    Origin is not this loopback address is refused (DNS-rebinding guard).
  - Actions name an item id from the server's own inventory, never a raw path,
    and the server recomputes every safety check at execution time.
  - Git worktrees, repos under ~/Code, and treehouse pool slots are removed
    only after: no live firstmate task owns the path (state/*.meta worktree=
    or home=), the tree is clean (no uncommitted or untracked files), every
    local branch with commits on no remote ref is pushed WITHOUT force to a
    GitHub remote and verified with ls-remote, and an entry is appended to
    <FM_HOME>/data/disk-lens/backup-log.md. Any failure refuses the removal.
    Removal is `git worktree remove` (no --force) for a linked worktree,
    `treehouse destroy <path> --yes` (no --include-* flag) for a pool slot,
    and a directory delete for a primary repo with no linked worktrees and
    no stash. When <FM_HOME>/config/disk-lens-log-repo exists (key=value:
    repo=<checkout>, optional remote=origin, branch=master,
    file=firstmate/disk-lens-backup-log.md), the same entry is also committed
    to that file alone on the remote branch and pushed without force, using a
    private index so the checkout's files, index, and HEAD are untouched; a
    failed mirror push refuses the removal.
  - Every other path goes to the macOS Trash (`trash`, else Finder through
    osascript); this server never unlinks a personal file.
  - Docker items use docker rmi / rm / volume rm without -f; the build cache
    uses `docker builder prune -f`, where -f only skips docker's own y/N
    prompt that the page confirmation replaces.
  - Kill sends SIGTERM; SIGKILL needs a prior SIGTERM to the same process
    (same pid and start time) and a second confirmation. Processes of
    firstmate, tmux, the agent, or this tool carry a warning that the page
    must acknowledge.
  - "Ask AI" runs `claude -p --model claude-haiku-5-5 --tools ""` on context
    gathered read-only here; "Hand to firstmate" writes a note through
    bin/fm-inbox.sh. Neither spawns work.

The server exits on POST /api/quit, when --watch-pid stops existing, or after
--idle-minutes without any page request (default 60).

Exit status: 0 normal stop, 2 invalid arguments (including a non-loopback
--bind).
"""

import argparse
import concurrent.futures
import ctypes
import ctypes.util
import datetime
import hmac
import http.server
import json
import os
import pwd
import re
import shutil
import signal
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid

LOOPBACK = "127.0.0.1"
HAIKU_MODEL = "claude-haiku-5-5"
SELF_DIR = os.path.dirname(os.path.abspath(__file__))
CODE_ROOT = os.path.dirname(SELF_DIR)
PAGE_FILE = os.path.join(SELF_DIR, "fm-disk-lens.html")
GIT_ENV = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(cmd, cwd=None, timeout=60, stdin=None, env=None):
    try:
        p = subprocess.run(
            cmd,
            cwd=cwd,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env or GIT_ENV,
        )
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, "", "%s: not found" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "", "%s: timed out after %ss" % (cmd[0], timeout)


def git(path, *args, timeout=60):
    return run(["git", "-C", path, *args], timeout=timeout)


def real(p):
    return os.path.realpath(os.path.expanduser(p))


def is_within(child, parent):
    child, parent = real(child), real(parent)
    return child == parent or child.startswith(parent.rstrip("/") + "/")


# --------------------------------------------------------------------------
# Context: home layout and protected paths


class Context:
    def __init__(self, fm_home):
        self.home = real(os.path.expanduser("~"))
        self.fm_home = real(fm_home)
        self.code_dir = os.path.join(self.home, "Code")
        self.treehouse_root = real(os.environ.get("TREEHOUSE_ROOT") or os.path.join(self.home, ".treehouse"))
        self.worktree_roots = [
            self.treehouse_root,
            os.path.join(self.home, ".tmux-worktree"),
            os.path.join(self.home, ".treehouse-before"),
        ]
        lib = os.path.join(self.home, "Library")
        # Whole-path refusals: deleting or trashing these (or an ancestor of
        # them) loses the home, credentials, or the tool itself.
        self.protected = [
            self.home,
            lib,
            self.code_dir,
            self.fm_home,
            CODE_ROOT,
            self.treehouse_root,
            os.path.join(lib, "Keychains"),
            os.path.join(lib, "Mobile Documents"),
            os.path.join(lib, "Containers", "com.docker.docker"),
            os.path.join(lib, "Group Containers", "group.com.docker"),
            os.path.join(self.home, ".ssh"),
            os.path.join(self.home, ".gnupg"),
            os.path.join(self.home, ".aws"),
            os.path.join(self.home, ".config", "gh"),
            os.path.join(self.home, ".Trash"),
            os.path.join(self.fm_home, "data", "disk-lens"),
        ]

    def protected_reason(self, path):
        rp = real(path)
        for p in self.protected:
            if is_within(p, rp):
                return "protected path: %s holds %s" % (rp, p) if rp != real(p) else "protected path: %s" % rp
        return None

    def task_owners(self):
        """Map of realpath -> task id for every state/*.meta worktree= or home=."""
        owners = {}
        state = os.path.join(self.fm_home, "state")
        try:
            names = sorted(os.listdir(state))
        except OSError:
            return owners
        for name in names:
            if not name.endswith(".meta"):
                continue
            tid = name[: -len(".meta")]
            for k, v in read_meta(os.path.join(state, name)).items():
                if k in ("worktree", "home") and v:
                    owners[real(v)] = tid
        return owners

    def task_ids(self):
        try:
            return set(n[: -len(".meta")] for n in os.listdir(os.path.join(self.fm_home, "state")) if n.endswith(".meta"))
        except OSError:
            return set()

    def owner_of(self, path):
        for owned, tid in self.task_owners().items():
            if is_within(path, owned) or is_within(owned, path):
                return tid, owned
        for tid in self.task_ids():
            d = os.path.join(self.fm_home, "data", tid)
            if is_within(path, d) or is_within(d, path):
                return tid, d
        return None, None


def read_meta(path):
    out = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.rstrip("\n")
                if "=" in line:
                    k, v = line.split("=", 1)
                    out[k] = v
    except OSError:
        pass
    return out


def tail_lines(path, n):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return [l.rstrip("\n") for l in f.readlines()[-n:]]
    except OSError:
        return []


# --------------------------------------------------------------------------
# Sizes


def du_bytes(path):
    rc, out, _ = run(["du", "-skx", path], timeout=1800)
    try:
        return int(out.split()[0]) * 1024
    except (ValueError, IndexError):
        return None


_libc = None


def _private_size_fn():
    """getattrlist(ATTR_CMNEXT_PRIVATESIZE): bytes of a file shared with no
    APFS clone. Returns None off macOS."""
    global _libc
    if sys.platform != "darwin":
        return None
    if _libc is None:
        _libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)

    class AttrList(ctypes.Structure):
        _fields_ = [
            ("bitmapcount", ctypes.c_ushort),
            ("reserved", ctypes.c_uint16),
            ("commonattr", ctypes.c_uint32),
            ("volattr", ctypes.c_uint32),
            ("dirattr", ctypes.c_uint32),
            ("fileattr", ctypes.c_uint32),
            ("forkattr", ctypes.c_uint32),
        ]

    attrs = AttrList(5, 0, 0, 0, 0, 0, 0x8)
    buf = ctypes.create_string_buffer(64)
    fsopt = 0x1 | 0x20  # FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED

    def private(p):
        if _libc.getattrlist(os.fsencode(p), ctypes.byref(attrs), buf, 64, fsopt) != 0:
            return None
        return struct.unpack_from("<Iq", buf.raw)[1]

    return private


def private_bytes(path):
    """Clone-aware lower bound of what deleting <path> frees on APFS."""
    fn = _private_size_fn()
    if fn is None:
        return None
    total = 0
    for dp, _dn, fns in os.walk(path):
        for f in fns:
            p = os.path.join(dp, f)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if (st.st_mode & 0o170000) != 0o100000:
                continue
            s = fn(p)
            total += s if s is not None else st.st_blocks * 512
    return total


def parse_docker_size(s):
    m = re.match(r"^\s*([\d.]+)\s*([kKMGTP]?B)\s*$", s or "")
    if not m:
        return None
    mult = {"B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15}[m.group(2)]
    return int(float(m.group(1)) * mult)


# --------------------------------------------------------------------------
# Inventory


class Inventory:
    def __init__(self, ctx, sources=None, measure=True):
        self.ctx = ctx
        self.sources = sources or ALL_SOURCES
        self.measure = measure
        self.lock = threading.Lock()
        self.items = {}
        self.scan_gen = 0
        self.scanning = False
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=4)
        self.errors = []

    def put(self, item):
        item.setdefault("size", None)
        item.setdefault("details", {})
        with self.lock:
            self.items[item["id"]] = item
        return item

    def get(self, iid):
        with self.lock:
            return self.items.get(iid)

    def snapshot(self, tab):
        with self.lock:
            return [dict(i) for i in self.items.values() if i["tab"] == tab]

    def rescan(self):
        with self.lock:
            if self.scanning:
                return
            self.scanning = True
            self.scan_gen += 1
            gen = self.scan_gen
            self.items = {}
            self.errors = []
        threading.Thread(target=self._scan, args=(gen,), daemon=True).start()

    def _scan(self, gen):
        try:
            for fn in self.sources:
                try:
                    fn(self)
                except Exception as e:  # one broken source must not hide the rest
                    with self.lock:
                        self.errors.append("%s: %s" % (fn.__name__, e))
            by_path = {}
            if not self.measure:
                return
            with self.lock:
                for i in self.items.values():
                    if i.get("needs_du"):
                        by_path.setdefault(i["path"], []).append(i)
            futs = [self.pool.submit(self._measure, by_path[p], gen) for p in sorted(by_path)]
            concurrent.futures.wait(futs)
        finally:
            with self.lock:
                if gen == self.scan_gen:
                    self.scanning = False

    def _measure(self, items, gen):
        if gen != self.scan_gen:
            return
        path = items[0]["path"]
        size = du_bytes(path)
        extra = {}
        if any(i["kind"] in ("worktree", "repo", "pool-slot") for i in items):
            extra = git_summary(path)
        with self.lock:
            for item in items:
                item["size"] = size
                if item["kind"] in ("worktree", "repo", "pool-slot"):
                    item["details"].update(extra)
                item["needs_du"] = False


def item_id(kind, key):
    return uuid.uuid5(uuid.NAMESPACE_URL, "%s:%s" % (kind, key)).hex[:16]


def path_item(inv, tab, group, kind, path, label=None, action="trash", note=None):
    return inv.put(
        {
            "id": item_id(kind, real(path)),
            "tab": tab,
            "group": group,
            "kind": kind,
            "path": real(path),
            "label": label or path.replace(inv.ctx.home, "~", 1),
            "action": action,
            "note": note,
            "needs_du": True,
        }
    )


def scan_docker(inv):
    rc, out, err = run(["docker", "system", "df", "-v", "--format", "json"], timeout=60)
    if rc != 0:
        inv.put(
            {
                "id": item_id("docker-off", "docker"),
                "tab": "disk",
                "group": "docker",
                "kind": "info",
                "path": "",
                "label": "Docker not reachable",
                "action": "none",
                "note": (err or out).strip()[:300],
            }
        )
        return
    d = json.loads(out)
    for im in d.get("Images") or []:
        name = "%s:%s" % (im.get("Repository"), im.get("Tag"))
        inv.put(
            {
                "id": item_id("docker-image", im["ID"]),
                "tab": "disk",
                "group": "docker",
                "kind": "docker-image",
                "path": "",
                "ref": im["ID"],
                "label": "image %s" % name,
                "size": parse_docker_size(im.get("UniqueSize")),
                "action": "docker",
                "note": "unique %s of %s total; %s container(s) use it; created %s"
                % (im.get("UniqueSize"), im.get("Size"), im.get("Containers"), im.get("CreatedSince")),
                "details": {"containers": im.get("Containers"), "repository": im.get("Repository")},
            }
        )
        if (im.get("Repository") or "").startswith("ocr-bench"):
            fm = dict(inv.get(item_id("docker-image", im["ID"])))
            fm.update(id=item_id("fm-docker-image", im["ID"]), tab="firstmate", group="bench docker images", details=dict(fm["details"]))
            inv.put(fm)
    for c in d.get("Containers") or []:
        inv.put(
            {
                "id": item_id("docker-container", c["ID"]),
                "tab": "disk",
                "group": "docker",
                "kind": "docker-container",
                "path": "",
                "ref": c["ID"],
                "label": "container %s (%s)" % (c.get("Names"), c.get("Image")),
                "size": parse_docker_size((c.get("Size") or "").split(" ")[0]),
                "action": "docker",
                "note": "%s; %s" % (c.get("State"), c.get("Status")),
                "details": {"state": c.get("State")},
            }
        )
    for v in d.get("Volumes") or []:
        inv.put(
            {
                "id": item_id("docker-volume", v["Name"]),
                "tab": "disk",
                "group": "docker",
                "kind": "docker-volume",
                "path": "",
                "ref": v["Name"],
                "label": "volume %s" % v["Name"],
                "size": parse_docker_size(v.get("Size")),
                "action": "docker",
                "note": "%s container link(s)" % v.get("Links"),
                "details": {"links": v.get("Links")},
            }
        )
    caches = d.get("BuildCache") or []
    if caches:
        total = sum(parse_docker_size(c.get("Size")) or 0 for c in caches)
        unused = sum(parse_docker_size(c.get("Size")) or 0 for c in caches if c.get("InUse") != "true")
        inv.put(
            {
                "id": item_id("docker-buildcache", "all"),
                "tab": "disk",
                "group": "docker",
                "kind": "docker-buildcache",
                "path": "",
                "ref": "builder",
                "label": "build cache (%d entries)" % len(caches),
                "size": unused,
                "action": "docker",
                "note": "prune frees the unused part; %.1f GB total" % (total / 1e9),
            }
        )


def git_summary(path):
    out = {}
    rc, br, _ = git(path, "symbolic-ref", "-q", "--short", "HEAD")
    out["branch"] = br.strip() if rc == 0 else "(detached)"
    rc, st, _ = git(path, "status", "--porcelain=v1", "--untracked-files=normal", timeout=120)
    if rc == 0:
        lines = [l for l in st.splitlines() if l]
        out["dirty"] = len(lines)
    rc, ab, _ = git(path, "rev-list", "--left-right", "--count", "@{u}...HEAD")
    if rc == 0 and ab.split():
        behind, ahead = ab.split()[:2]
        out["ahead"], out["behind"] = int(ahead), int(behind)
    rc, lc, _ = git(path, "log", "-1", "--format=%cs %s")
    if rc == 0:
        out["last_commit"] = lc.strip()[:120]
    return out


def is_git_worktree_dir(p):
    return os.path.isfile(os.path.join(p, ".git"))


def is_git_repo_dir(p):
    return os.path.isdir(os.path.join(p, ".git"))


def treehouse_slot_of(ctx, path):
    """(pool_dir, slot_name) when <path> is <treehouse_root>/<pool>/<slot>/<repo>."""
    rp = real(path)
    root = ctx.treehouse_root.rstrip("/") + "/"
    if not rp.startswith(root):
        return None
    parts = rp[len(root):].split("/")
    if len(parts) == 3:
        return os.path.join(ctx.treehouse_root, parts[0]), parts[1]
    return None


def scan_git(inv):
    ctx = inv.ctx
    with inv.lock:
        seen = set(i["path"] for i in inv.items.values() if i["tab"] == "disk")
    worktrees = []
    repos = []
    try:
        code_children = sorted(os.listdir(ctx.code_dir))
    except OSError:
        code_children = []
    for name in code_children:
        p = os.path.join(ctx.code_dir, name)
        if not os.path.isdir(p) or os.path.islink(p):
            continue
        if is_git_repo_dir(p):
            repos.append(p)
        elif is_git_worktree_dir(p):
            worktrees.append(p)
        else:
            path_item(inv, "disk", "personal", "path", p, note="not a git repo; goes to Trash")
    try:
        project_names = sorted(os.listdir(os.path.join(ctx.fm_home, "projects")))
    except OSError:
        project_names = []
    for name in project_names:
        p = os.path.join(ctx.fm_home, "projects", name)
        if os.path.isdir(p) and is_git_repo_dir(p):
            repos.append(p)
    for repo in repos:
        rc, out, _ = git(repo, "worktree", "list", "--porcelain")
        for line in out.splitlines():
            if line.startswith("worktree "):
                wt = line[len("worktree "):]
                if real(wt) != real(repo) and os.path.isdir(wt):
                    worktrees.append(wt)
    for root in ctx.worktree_roots:
        for dp, dn, _fn in walk_depth(root, 3):
            if ".git" in os.listdir(dp) and is_git_worktree_dir(dp):
                worktrees.append(dp)
                dn[:] = []
            elif is_git_repo_dir(dp) and dp != root:
                repos.append(dp)
                dn[:] = []
    for repo in repos:
        if real(repo) in seen:
            continue
        seen.add(real(repo))
        group = "repo" if is_within(repo, ctx.code_dir) else "worktree"
        path_item(inv, "disk", group, "repo", repo, action="git-backup")
    for wt in worktrees:
        if real(wt) in seen:
            continue
        seen.add(real(wt))
        slot = treehouse_slot_of(ctx, wt)
        note = "treehouse pool slot %s/%s" % (os.path.basename(slot[0]), slot[1]) if slot else None
        path_item(inv, "disk", "worktree", "worktree", wt, action="git-backup", note=note)


def walk_depth(root, depth):
    root = real(root)
    if not os.path.isdir(root):
        return
    base = root.count("/")
    for dp, dn, fn in os.walk(root):
        dn[:] = sorted(d for d in dn if not os.path.islink(os.path.join(dp, d)) and d != ".git")
        if dp.count("/") - base >= depth:
            dn[:] = []
        yield dp, dn, fn


CACHE_PATHS = [
    ".npm",
    ".yarn",
    "Library/pnpm",
    ".cargo/registry",
    "go/pkg/mod",
    ".gradle/caches",
    ".m2/repository",
    ".pub-cache",
    "Library/Developer/Xcode/DerivedData",
    "Library/Developer/CoreSimulator/Caches",
]


def scan_caches(inv):
    ctx = inv.ctx
    for parent in ("Library/Caches", ".cache"):
        d = os.path.join(ctx.home, parent)
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            p = os.path.join(d, n)
            if os.path.isdir(p) and not os.path.islink(p):
                path_item(inv, "disk", "cache", "path", p)
    for rel in CACHE_PATHS:
        p = os.path.join(ctx.home, rel)
        if os.path.isdir(p) and not os.path.islink(p):
            path_item(inv, "disk", "cache", "path", p)


PERSONAL_SKIP = {"Library", "Code", ".Trash", ".cache"}


def scan_personal(inv):
    ctx = inv.ctx
    covered = set(real(os.path.join(ctx.home, r)) for r in CACHE_PATHS)
    covered.update(real(r) for r in ctx.worktree_roots)
    try:
        names = sorted(os.listdir(ctx.home))
    except OSError:
        names = []
    for n in names:
        p = os.path.join(ctx.home, n)
        if n in PERSONAL_SKIP or os.path.islink(p) or real(p) in covered:
            continue
        if not (os.path.isdir(p) or os.path.isfile(p)):
            continue
        if any(is_within(c, p) for c in covered):
            # a parent of a covered cache (for example ~/go): list its other children
            for c in sorted(os.listdir(p)):
                cp = os.path.join(p, c)
                if not any(is_within(cv, cp) for cv in covered) and not os.path.islink(cp):
                    path_item(inv, "disk", "personal", "path", cp)
            continue
        path_item(inv, "disk", "personal", "path", p)
    lib = os.path.join(ctx.home, "Library")
    try:
        lib_names = sorted(os.listdir(lib))
    except OSError:
        lib_names = []
    expand = {"Application Support", "Containers", "Group Containers"}
    for n in lib_names:
        p = os.path.join(lib, n)
        if n == "Caches" or os.path.islink(p) or real(p) in covered or not os.path.isdir(p):
            continue
        if n in expand:
            try:
                kids = sorted(os.listdir(p))
            except OSError:
                continue
            for k in kids:
                kp = os.path.join(p, k)
                if os.path.isdir(kp) and not os.path.islink(kp):
                    note = "app data; trashing it can reset or break that app"
                    path_item(inv, "disk", "personal", "path", kp, note=note)
            continue
        if any(is_within(c, p) for c in covered):
            continue
        path_item(inv, "disk", "personal", "path", p)


def scan_system(inv):
    rc, out, _ = run(["sysctl", "-n", "vm.swapusage"], timeout=10)
    if rc == 0:
        m = re.search(r"used = ([\d.]+)M", out)
        used = int(float(m.group(1)) * 1024 * 1024) if m else None
        inv.put(
            {
                "id": item_id("swap", "vm"),
                "tab": "disk",
                "group": "system",
                "kind": "info",
                "path": "/System/Volumes/VM",
                "label": "macOS swap files",
                "size": used,
                "action": "none",
                "note": "swap: %s; frees itself when memory pressure drops (see RAM tab)" % out.strip(),
            }
        )


# --------------------------------------------------------------------------
# Firstmate resources


def treehouse_pools(ctx):
    """[(pool_dir, main_repo_root)] for every treehouse pool under the root."""
    pools = []
    try:
        names = sorted(os.listdir(ctx.treehouse_root))
    except OSError:
        return pools
    for n in names:
        pool = os.path.join(ctx.treehouse_root, n)
        if not os.path.isdir(pool):
            continue
        main = None
        for slot in sorted(os.listdir(pool)):
            sp = os.path.join(pool, slot)
            if not os.path.isdir(sp):
                continue
            for repo in os.listdir(sp):
                rp = os.path.join(sp, repo)
                if is_git_worktree_dir(rp):
                    rc, out, _ = git(rp, "rev-parse", "--path-format=absolute", "--git-common-dir")
                    if rc == 0:
                        main = os.path.dirname(out.strip())
                        break
            if main:
                break
        if main and os.path.isdir(main):
            pools.append((pool, main))
    return pools


def treehouse_status(main):
    rc, out, err = run(["treehouse", "status", "--json"], cwd=main, timeout=60)
    if rc != 0:
        return None, (err or out).strip()[:300]
    try:
        return json.loads(out), None
    except ValueError as e:
        return None, "unparseable treehouse status: %s" % e


def scan_firstmate(inv):
    ctx = inv.ctx
    owners = ctx.task_owners()
    for pool, main in treehouse_pools(ctx):
        entries, err = treehouse_status(main)
        if entries is None:
            inv.put(
                {
                    "id": item_id("pool-err", pool),
                    "tab": "firstmate",
                    "group": "pool",
                    "kind": "info",
                    "path": pool,
                    "label": "pool %s: treehouse status failed" % os.path.basename(pool),
                    "action": "none",
                    "note": err,
                }
            )
            continue
        for e in entries:
            path = e.get("path") or ""
            if not is_within(path, pool):
                continue
            owner = owners.get(real(path))
            procs = e.get("processes") or []
            item = path_item(
                inv,
                "firstmate",
                "pool %s" % os.path.basename(pool),
                "pool-slot",
                path,
                label="slot %s  %s" % (e.get("name"), path.replace(ctx.home, "~", 1)),
                action="treehouse-slot",
            )
            item["details"].update(
                {
                    "pool": os.path.basename(pool),
                    "slot": e.get("name"),
                    "status": e.get("status"),
                    "branch": e.get("branch") or ("(detached)" if e.get("detached") else ""),
                    "holder": e.get("lease_holder") or "",
                    "task": owner or "",
                    "processes": len(procs),
                    "main_repo": main,
                }
            )
    data = os.path.join(ctx.fm_home, "data")
    live = ctx.task_ids()
    try:
        data_names = sorted(os.listdir(data))
    except OSError:
        data_names = []
    for n in data_names:
        p = os.path.join(data, n)
        if not os.path.isdir(p) or os.path.islink(p) or n == "disk-lens":
            continue
        note = "records of live task %s" % n if n in live else "firstmate records (reports, logs, artifacts)"
        path_item(inv, "firstmate", "firstmate data", "path", p, label="data/%s" % n, note=note)
    state = os.path.join(ctx.fm_home, "state")
    try:
        metas = sorted(n for n in os.listdir(state) if n.endswith(".meta"))
    except OSError:
        metas = []
    for n in metas:
        tid = n[: -len(".meta")]
        meta = read_meta(os.path.join(state, n))
        last = tail_lines(os.path.join(state, tid + ".status"), 1)
        inv.put(
            {
                "id": item_id("task", tid),
                "tab": "firstmate",
                "group": "live tasks",
                "kind": "task",
                "path": meta.get("worktree") or meta.get("home") or "",
                "ref": tid,
                "label": "task %s (%s, %s)" % (tid, meta.get("kind", "?"), meta.get("mode", "?")),
                "action": "none",
                "note": (last[0][:200] if last else "no status yet"),
                "details": {k: meta.get(k, "") for k in ("kind", "mode", "branch", "harness", "model", "worktree", "project")},
            }
        )
    for proc in list_processes():
        args = proc["args"]
        what = None
        if "fm-watch" in args:
            what = "watcher"
        elif "lavish" in args:
            what = "lavish session"
        elif ctx.fm_home in args or CODE_ROOT in args:
            what = "firstmate helper"
        if not what or proc["pid"] == os.getpid():
            continue
        inv.put(
            {
                "id": item_id("fmproc", "%s:%s" % (proc["pid"], proc["lstart"])),
                "tab": "firstmate",
                "group": what + "s",
                "kind": "process",
                "path": "",
                "ref": str(proc["pid"]),
                "pid": proc["pid"],
                "lstart": proc["lstart"],
                "label": "%s pid %d" % (what, proc["pid"]),
                "size": proc["rss"],
                "action": "kill",
                "note": args[:240],
            }
        )


# --------------------------------------------------------------------------
# Processes


PS_LINE = re.compile(r"^\s*(\d+)\s+(\d+)\s+([\d.]+)\s+(\d+)\s+(\S+)\s+(\w{3}\s+\w{3}\s+\d+\s+[\d:]+\s+\d{4})\s+(.*)$")


def current_user():
    return pwd.getpwuid(os.getuid()).pw_name


def list_processes():
    rc, out, _ = run(["ps", "-A", "-ww", "-o", "pid=,ppid=,pcpu=,rss=,user=,lstart=,comm="], timeout=20)
    rc2, out2, _ = run(["ps", "-A", "-ww", "-o", "pid=,args="], timeout=20)
    args = {}
    for line in out2.splitlines():
        parts = line.strip().split(None, 1)
        if parts and parts[0].isdigit():
            args[int(parts[0])] = parts[1] if len(parts) > 1 else ""
    procs = []
    for line in out.splitlines():
        m = PS_LINE.match(line)
        if not m:
            continue
        pid, ppid = int(m.group(1)), int(m.group(2))
        comm = m.group(7).strip()
        procs.append(
            {
                "pid": pid,
                "ppid": ppid,
                "cpu": float(m.group(3)),
                "rss": int(m.group(4)) * 1024,
                "user": m.group(5),
                "lstart": " ".join(m.group(6).split()),
                "comm": comm,
                "app": app_name(comm),
                "args": args.get(pid, comm),
            }
        )
    return procs


def app_name(comm):
    m = re.search(r"/([^/]+)\.app/", comm + "/")
    if m:
        return m.group(1)
    return os.path.basename(comm) or comm


class ProcGuard:
    def __init__(self, ctx, watch_pid):
        self.ctx = ctx
        self.watch_pid = watch_pid
        self.term_sent = {}
        self.lock = threading.Lock()

    def warnings(self, proc, by_pid):
        w = []
        pid = proc["pid"]
        me = os.getpid()
        if pid == me:
            w.append("this is disk-lens itself")
        chain, cur, hops = [], by_pid.get(me), 0
        while cur and hops < 64:
            chain.append(cur["pid"])
            cur = by_pid.get(cur["ppid"])
            hops += 1
        if pid in chain and pid != me:
            w.append("an ancestor of disk-lens (the agent session that started it)")
        if self.watch_pid and pid == self.watch_pid:
            w.append("the agent session disk-lens belongs to")
        base = os.path.basename(proc["comm"])
        if base.startswith("tmux"):
            w.append("a tmux process; killing the server closes every pane")
        if self.ctx.fm_home in proc["args"] or CODE_ROOT in proc["args"]:
            w.append("a firstmate process")
        cur, hops = by_pid.get(proc["ppid"]), 0
        while cur and hops < 64:
            if os.path.basename(cur["comm"]).startswith("tmux"):
                w.append("runs inside tmux: may be a firstmate worker or agent pane")
                break
            cur = by_pid.get(cur["ppid"])
            hops += 1
        return w

    def kill(self, pid, lstart, sig_name, ack):
        procs = list_processes()
        by_pid = {p["pid"]: p for p in procs}
        proc = by_pid.get(pid)
        if not proc:
            return 404, {"error": "process %d is gone" % pid}
        if proc["lstart"] != lstart:
            return 409, {"error": "pid %d now belongs to a different process; refresh" % pid}
        if proc["user"] != current_user() or pid <= 1:
            return 403, {"error": "not your process"}
        warns = self.warnings(proc, by_pid)
        if warns and not ack:
            return 409, {"error": "needs warning acknowledgement", "warnings": warns}
        key = (pid, lstart)
        if sig_name == "KILL":
            with self.lock:
                if key not in self.term_sent:
                    return 409, {"error": "send SIGTERM first; SIGKILL is only the second step"}
            sig = signal.SIGKILL
        elif sig_name == "TERM":
            sig = signal.SIGTERM
        else:
            return 400, {"error": "signal must be TERM or KILL"}
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            return 404, {"error": "process %d is gone" % pid}
        except PermissionError:
            return 403, {"error": "permission denied"}
        with self.lock:
            self.term_sent[key] = time.time()
        time.sleep(0.5)
        alive = any(p["pid"] == pid and p["lstart"] == lstart for p in list_processes())
        return 200, {"ok": True, "signal": sig_name, "alive": alive}


# --------------------------------------------------------------------------
# Git backup and removal


def github_remotes(path):
    """[(name, configured url)] for remotes on github.com, read from the raw
    remote.<name>.url config (`git remote -v` shows insteadOf rewrites)."""
    rc, out, _ = git(path, "config", "--get-regexp", r"^remote\..*\.url$")
    remotes = []
    for line in out.splitlines():
        key, _, url = line.partition(" ")
        name = key[len("remote."):-len(".url")]
        if github_slug(url)[0]:
            remotes.append((name, url))
    return remotes


def github_slug(url):
    m = re.search(r"github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$", url)
    return (m.group(1), m.group(2)) if m else (None, None)


class RemoteHeads:
    """Live `git ls-remote` view per remote, so a stale remote-tracking ref
    (a branch deleted on GitHub but not pruned here) never counts as a backup."""

    def __init__(self, path):
        self.path = path
        self.cache = {}

    def sha(self, remote, ref):
        if remote not in self.cache:
            rc, out, _ = git(self.path, "ls-remote", remote, timeout=120)
            heads = {}
            if rc == 0:
                for line in out.splitlines():
                    parts = line.split("\t")
                    if len(parts) == 2:
                        heads[parts[1]] = parts[0]
            self.cache[remote] = heads
        name = "HEAD" if ref == "HEAD" else "refs/heads/" + ref
        return self.cache[remote].get(name)


def ref_on_remote(path, ref, heads, allowed):
    """The first GitHub remote-tracking ref containing <ref> whose sha still
    matches the live remote, or ''."""
    rc, out, _ = git(path, "for-each-ref", "--contains", ref, "--format=%(refname)\t%(objectname)", "refs/remotes/")
    if rc != 0:
        return ""
    for line in out.splitlines():
        full, _, sha = line.partition("\t")
        rest = full[len("refs/remotes/"):]
        remote, _, branch = rest.partition("/")
        if branch and remote in allowed and heads.sha(remote, branch) == sha:
            return rest
    return ""


class Plan:
    def __init__(self):
        self.refusals = []
        self.steps = []
        self.pushes = []  # (branch, remote_name, remote_url, dest)
        self.already = []  # (branch, remote ref)
        self.facts = {}

    def as_dict(self):
        return {
            "ok": not self.refusals,
            "refusals": self.refusals,
            "steps": self.steps,
            "facts": self.facts,
        }


def plan_git(ctx, item, slot_entry=None):
    path = item["path"]
    plan = Plan()
    if not os.path.isdir(path):
        plan.refusals.append("path no longer exists")
        return plan
    pr = ctx.protected_reason(path)
    if pr:
        plan.refusals.append(pr)
    tid, owned = ctx.owner_of(path)
    if tid:
        plan.refusals.append("live firstmate task %s owns %s; firstmate cleanup owns it" % (tid, owned))
    if slot_entry is not None:
        if slot_entry.get("lease_holder"):
            plan.refusals.append("slot is leased by %s; firstmate cleanup owns it" % slot_entry["lease_holder"])
        if slot_entry.get("processes"):
            names = ", ".join("%s (%s)" % (p.get("name"), p.get("pid")) for p in slot_entry["processes"][:5])
            plan.refusals.append("processes are running inside the slot: %s" % names)
    is_worktree = is_git_worktree_dir(path)
    rc, st, err = git(path, "status", "--porcelain=v1", "--untracked-files=normal", timeout=120)
    if rc != 0:
        plan.refusals.append("git status failed: %s" % err.strip()[:200])
    elif st.strip():
        lines = st.splitlines()
        plan.refusals.append(
            "uncommitted or untracked changes (%d): %s - commit them yourself or use Trash"
            % (len(lines), "; ".join(l.strip() for l in lines[:5]))
        )
    rc, ign, _ = git(path, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory")
    ignored = [l for l in ign.splitlines() if l]
    if ignored:
        plan.facts["ignored_deleted"] = ignored[:12] + (["... %d more" % (len(ignored) - 12)] if len(ignored) > 12 else [])
    remotes = github_remotes(path)
    if not remotes:
        plan.refusals.append("no GitHub remote: nothing to back the work up to - use Trash instead")
    heads = RemoteHeads(path)
    allowed = set(r[0] for r in remotes)
    main_repo = path
    if is_worktree:
        rc, cd, _ = git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")
        main_repo = os.path.dirname(cd.strip()) if rc == 0 else None
        if not main_repo:
            plan.refusals.append("cannot find the worktree's main repository")
        rc, br, _ = git(path, "symbolic-ref", "-q", "--short", "HEAD")
        branches = [br.strip()] if rc == 0 else []
        if not branches:
            on = ref_on_remote(path, "HEAD", heads, allowed)
            if on:
                plan.already.append(("HEAD (detached)", on))
            else:
                plan.refusals.append("detached HEAD has commits on no remote branch - check out a branch first")
    else:
        rc, out, _ = git(path, "worktree", "list", "--porcelain")
        others = [
            l[len("worktree "):]
            for l in out.splitlines()
            if l.startswith("worktree ") and real(l[len("worktree "):]) != real(path) and os.path.isdir(l[len("worktree "):])
        ]
        if others:
            plan.refusals.append("repo still has %d linked worktree(s), e.g. %s - remove those first" % (len(others), others[0]))
        rc, stash, _ = git(path, "stash", "list")
        if stash.strip():
            plan.refusals.append("repo has %d stash entr(ies) that would be lost" % len(stash.splitlines()))
        rc, out, _ = git(path, "for-each-ref", "--format=%(refname:short)", "refs/heads/")
        branches = [b for b in out.splitlines() if b]
    for b in branches:
        on = ref_on_remote(path, "refs/heads/" + b, heads, allowed)
        if on:
            plan.already.append((b, on))
            continue
        if not remotes:
            continue
        rc, rem, _ = git(path, "config", "--get", "branch.%s.remote" % b)
        rem = rem.strip()
        chosen = next((r for r in remotes if r[0] == rem), None) or next((r for r in remotes if r[0] == "origin"), None) or remotes[0]
        dest = b
        rc, merge, _ = git(path, "config", "--get", "branch.%s.merge" % b)
        if chosen[0] == rem and merge.strip().startswith("refs/heads/"):
            dest = merge.strip()[len("refs/heads/"):]
        plan.pushes.append((b, chosen[0], chosen[1], dest))
    for b, rname, url, dest in plan.pushes:
        plan.steps.append("git push %s refs/heads/%s:refs/heads/%s (no force), then verify with ls-remote" % (rname, b, dest))
    for b, on in plan.already:
        plan.steps.append("%s already on %s - nothing to push" % (b, on))
    plan.steps.append("append an entry to %s" % os.path.join(ctx.fm_home, "data", "disk-lens", "backup-log.md"))
    conf = log_mirror_config(ctx)
    if conf and conf.get("error"):
        plan.refusals.append("log mirror misconfigured: %s" % conf["error"])
    elif conf:
        plan.steps.append("commit and push only %s to %s %s in %s (removal waits for it)" % (conf["file"], conf["remote"], conf["branch"], conf["repo"]))
    if slot_entry is not None or treehouse_slot_of(ctx, path):
        plan.steps.append("treehouse destroy %s --yes (no --include-* flags)" % path)
        plan.facts["removal"] = "treehouse"
    elif is_worktree:
        plan.steps.append("git worktree remove %s (no --force)" % path)
        plan.facts["removal"] = "worktree"
    else:
        plan.steps.append("delete the directory %s" % path)
        plan.facts["removal"] = "directory"
    plan.facts["main_repo"] = main_repo
    plan.facts["remote"] = remotes[0][1] if remotes else ""
    return plan


def branch_summary(path, remote_name):
    base = None
    for cand in ("refs/remotes/%s/HEAD" % remote_name, "refs/remotes/%s/main" % remote_name, "refs/remotes/%s/master" % remote_name):
        rc, _, _ = git(path, "rev-parse", "--verify", "-q", cand)
        if rc == 0:
            base = cand
            break
    if not base:
        return "no default branch ref found on %s" % remote_name
    rc, n, _ = git(path, "rev-list", "--count", "%s..HEAD" % base)
    rc2, stat, _ = git(path, "diff", "--shortstat", "%s...HEAD" % base)
    short = base.replace("refs/remotes/", "")
    return "%s commit(s) not on %s;%s" % (n.strip() or "?", short, (" " + stat.strip()) if stat.strip() else " no file changes")


def append_backup_log(ctx, lines):
    d = os.path.join(ctx.fm_home, "data", "disk-lens")
    os.makedirs(d, exist_ok=True)
    log = os.path.join(d, "backup-log.md")
    new = not os.path.exists(log)
    with open(log, "a", encoding="utf-8") as f:
        if new:
            f.write(LOG_HEADER)
        f.write("\n" + "\n".join(lines) + "\n")
        f.flush()
        os.fsync(f.fileno())
    return log


LOG_HEADER = "# disk-lens backup log\n\nOne entry per worktree, repo, or pool slot removed through disk-lens, written after its branches were pushed and before removal.\n"


def log_mirror_config(ctx):
    """<FM_HOME>/config/disk-lens-log-repo, key=value lines: repo (required),
    remote (origin), branch (master), file (firstmate/disk-lens-backup-log.md).
    Absent file means no mirror."""
    path = os.path.join(ctx.fm_home, "config", "disk-lens-log-repo")
    if not os.path.isfile(path):
        return None
    conf = {"remote": "origin", "branch": "master", "file": "firstmate/disk-lens-backup-log.md"}
    conf.update({k.strip(): v.strip() for k, v in read_meta(path).items()})
    if not conf.get("repo"):
        return {"error": "%s has no repo= line" % path}
    conf["repo"] = real(conf["repo"])
    return conf


def mirror_backup_log(ctx, lines, subject):
    """Append <lines> to the configured file on the mirror repo's remote branch
    and push it, building the commit with plumbing on a private index so the
    checkout's working tree, index, and HEAD are never touched and no other
    file can be staged. Never forces; one retry on a lost race."""
    conf = log_mirror_config(ctx)
    if conf is None:
        return True, "no mirror configured"
    if conf.get("error"):
        return False, conf["error"]
    repo, remote, branch, fpath = conf["repo"], conf["remote"], conf["branch"], conf["file"]
    last = ""
    for _attempt in range(2):
        rc, out, err = git(repo, "fetch", "--quiet", remote, "refs/heads/%s" % branch, timeout=120)
        if rc != 0:
            return False, "fetch %s %s failed: %s" % (remote, branch, (err or out).strip()[:300])
        rc, base, err = git(repo, "rev-parse", "FETCH_HEAD^{commit}")
        if rc != 0:
            return False, "cannot resolve fetched %s: %s" % (branch, err.strip()[:200])
        base = base.strip()
        rc, existing, _ = git(repo, "show", "%s:%s" % (base, fpath))
        content = existing if rc == 0 else LOG_HEADER
        content = content.rstrip("\n") + "\n\n" + "\n".join(lines) + "\n"
        rc, blob, err = run(["git", "-C", repo, "hash-object", "-w", "--stdin"], stdin=content, timeout=60)
        if rc != 0:
            return False, "hash-object failed: %s" % err.strip()[:200]
        with tempfile.TemporaryDirectory(prefix="fm-disk-lens-index.") as td:
            env = dict(GIT_ENV, GIT_INDEX_FILE=os.path.join(td, "index"))
            steps = [
                ["git", "-C", repo, "read-tree", base],
                ["git", "-C", repo, "update-index", "--add", "--cacheinfo", "100644,%s,%s" % (blob.strip(), fpath)],
            ]
            for cmd in steps:
                rc, out, err = run(cmd, env=env, timeout=60)
                if rc != 0:
                    return False, "%s failed: %s" % (cmd[3], err.strip()[:200])
            rc, tree, err = run(["git", "-C", repo, "write-tree"], env=env, timeout=60)
            if rc != 0:
                return False, "write-tree failed: %s" % err.strip()[:200]
        rc, commit, err = git(repo, "commit-tree", tree.strip(), "-p", base, "-m", subject)
        if rc != 0:
            return False, "commit-tree failed: %s" % err.strip()[:200]
        commit = commit.strip()
        rc, out, err = git(repo, "push", "--porcelain", remote, "%s:refs/heads/%s" % (commit, branch), timeout=180)
        if rc == 0:
            rc, ls, _ = git(repo, "ls-remote", remote, "refs/heads/%s" % branch, timeout=120)
            if ls.split() and ls.split()[0] == commit:
                return True, "%s %s:%s at %s" % (remote, branch, fpath, commit[:12])
            return False, "pushed but ls-remote does not show %s" % commit[:12]
        last = (err or out).strip()[:300]
    return False, "push to %s %s failed: %s" % (remote, branch, last)


def execute_git(ctx, item, slot_entry=None):
    plan = plan_git(ctx, item, slot_entry)
    if plan.refusals:
        return 409, {"error": "refused", "plan": plan.as_dict()}
    path = item["path"]
    pushed = []
    for b, rname, url, dest in plan.pushes:
        rc, out, err = git(path, "push", "--porcelain", rname, "refs/heads/%s:refs/heads/%s" % (b, dest), timeout=300)
        if rc != 0:
            return 502, {"error": "push of %s to %s failed; nothing removed: %s" % (b, rname, (err or out).strip()[:400]), "plan": plan.as_dict()}
        rc, local, _ = git(path, "rev-parse", "refs/heads/" + b)
        rc2, remote, err2 = git(path, "ls-remote", rname, "refs/heads/" + dest, timeout=120)
        rsha = remote.split()[0] if remote.split() else ""
        if rc != 0 or rc2 != 0 or rsha != local.strip():
            return 502, {"error": "could not verify %s on %s after push (local %s, remote %s); nothing removed" % (b, rname, local.strip()[:12], rsha[:12] or err2.strip()[:200]), "plan": plan.as_dict()}
        owner, repo = github_slug(url)
        web = "https://github.com/%s/%s/tree/%s" % (owner, repo, dest) if owner else url
        pushed.append((b, rname, dest, local.strip(), web))
    remote_name = plan.pushes[0][1] if plan.pushes else (github_remotes(path) or [("origin", "")])[0][0]
    owner, repo = github_slug(plan.facts.get("remote", ""))
    rc, commits, _ = git(path, "log", "-5", "--format=%h %cs %s")
    entry = [
        "## %s - %s" % (now_utc(), path),
        "",
        "- repo: %s" % ("%s/%s" % (owner, repo) if owner else plan.facts.get("remote", "?")),
        "- kind: %s" % item["kind"],
    ]
    for b, rname, dest, sha, web in pushed:
        entry.append("- branch %s: pushed to %s/%s at %s - %s" % (b, rname, dest, sha[:12], web))
    for b, on in plan.already:
        entry.append("- branch %s: already on %s, not pushed" % (b, on))
    entry.append("- last commits:")
    entry.extend("  - %s" % l for l in commits.splitlines()[:5])
    entry.append("- summary: %s" % branch_summary(path, remote_name))
    if plan.facts.get("ignored_deleted"):
        entry.append("- ignored files deleted with it: %s" % ", ".join(plan.facts["ignored_deleted"]))
    entry.append("- removal: %s" % plan.facts["removal"])
    log = append_backup_log(ctx, entry)
    ok, mirror = mirror_backup_log(ctx, entry, "disk-lens: log removal of %s" % path.replace(ctx.home, "~", 1))
    if not ok:
        append_backup_log(ctx, ["- log mirror FAILED at %s, so %s was not removed: %s" % (now_utc(), path, mirror)])
        return 502, {"error": "branches backed up and logged locally, but the log mirror failed, so nothing was removed: %s" % mirror, "log": log, "pushed": [p[4] for p in pushed]}
    removal = plan.facts["removal"]
    if removal == "treehouse":
        rc, out, err = run(["treehouse", "destroy", path, "--yes"], cwd=plan.facts["main_repo"], timeout=600)
    elif removal == "worktree":
        rc, out, err = git(plan.facts["main_repo"], "worktree", "remove", path, timeout=600)
    else:
        try:
            shutil.rmtree(path)
            rc, out, err = 0, "", ""
        except OSError as e:
            rc, out, err = 1, "", str(e)
    if rc != 0 or os.path.exists(path):
        msg = (err or out).strip()[:600] or "path still exists"
        append_backup_log(ctx, ["- removal of %s FAILED at %s: %s" % (path, now_utc(), msg)])
        return 502, {"error": "branches backed up and logged, but removal failed: %s" % msg, "log": log, "pushed": [p[4] for p in pushed]}
    return 200, {"ok": True, "log": log, "mirror": mirror, "pushed": [p[4] for p in pushed], "already": [a[1] for a in plan.already]}


# --------------------------------------------------------------------------
# Trash and docker


def plan_trash(ctx, item):
    path = item["path"]
    plan = Plan()
    if not os.path.lexists(path):
        plan.refusals.append("path no longer exists")
    pr = ctx.protected_reason(path)
    if pr:
        plan.refusals.append(pr)
    tid, owned = ctx.owner_of(path)
    if tid:
        plan.refusals.append("live firstmate task %s owns %s; firstmate cleanup owns it" % (tid, owned))
    if is_git_worktree_dir(path):
        plan.facts["note"] = "a git worktree moved to Trash leaves a stale worktree record; `git worktree prune` clears it later"
    plan.steps.append("move %s to the macOS Trash (recoverable; never rm)" % path)
    return plan


def move_to_trash(path):
    if shutil.which("trash"):
        rc, out, err = run(["trash", path], timeout=600)
        if rc == 0 and not os.path.lexists(path):
            return True, ""
        first = (err or out).strip()
    else:
        first = "trash command not found"
    script = 'tell application "Finder" to delete (POSIX file "%s" as alias)' % path.replace("\\", "\\\\").replace('"', '\\"')
    rc, out, err = run(["osascript", "-e", script], timeout=600)
    if rc == 0 and not os.path.lexists(path):
        return True, ""
    return False, "%s; Finder: %s" % (first, (err or out).strip()[:300])


def execute_trash(ctx, item):
    plan = plan_trash(ctx, item)
    if plan.refusals:
        return 409, {"error": "refused", "plan": plan.as_dict()}
    ok, why = move_to_trash(item["path"])
    if not ok:
        return 502, {"error": "could not move to Trash: %s" % why}
    return 200, {"ok": True, "trashed": item["path"]}


def plan_docker(item):
    plan = Plan()
    k = item["kind"]
    if k == "docker-image":
        if (item["details"].get("containers") or "0") not in ("0", "-1", ""):
            plan.facts["note"] = "%s container(s) use this image; docker refuses unless they are removed first" % item["details"]["containers"]
        plan.steps.append("docker rmi %s (no -f)" % item["ref"])
    elif k == "docker-container":
        if item["details"].get("state") == "running":
            plan.refusals.append("container is running; stop it first (disk-lens never force-removes)")
        plan.steps.append("docker rm %s (no -f)" % item["ref"])
    elif k == "docker-volume":
        if (item["details"].get("links") or "0") not in ("0", "N/A"):
            plan.refusals.append("volume is attached to %s container(s)" % item["details"]["links"])
        plan.steps.append("docker volume rm %s" % item["ref"])
    elif k == "docker-buildcache":
        plan.steps.append("docker builder prune -f (removes unused build cache; -f only skips docker's own prompt)")
    else:
        plan.refusals.append("not a docker item")
    return plan


def execute_docker(item):
    plan = plan_docker(item)
    if plan.refusals:
        return 409, {"error": "refused", "plan": plan.as_dict()}
    cmd = {
        "docker-image": ["docker", "rmi", item["ref"]],
        "docker-container": ["docker", "rm", item["ref"]],
        "docker-volume": ["docker", "volume", "rm", item["ref"]],
        "docker-buildcache": ["docker", "builder", "prune", "-f"],
    }[item["kind"]]
    rc, out, err = run(cmd, timeout=600)
    if rc != 0:
        return 502, {"error": "%s failed: %s" % (" ".join(cmd[:3]), (err or out).strip()[:400])}
    return 200, {"ok": True, "output": out.strip()[-400:]}


# --------------------------------------------------------------------------
# Ask AI and firstmate hand-off


def gather_context(ctx, item):
    parts = ["Item: %s" % item["label"], "Kind: %s" % item["kind"]]
    if item.get("size") is not None:
        parts.append("Size: %.2f GiB" % (item["size"] / 2**30))
    if item.get("note"):
        parts.append("Note: %s" % item["note"])
    if item.get("details"):
        parts.append("Details: %s" % json.dumps(item["details"]))
    path = item.get("path")
    if item["kind"].startswith("docker-") and item.get("ref") and item["kind"] != "docker-buildcache":
        sub = ["volume", "inspect"] if item["kind"] == "docker-volume" else ["inspect"]
        rc, out, _ = run(["docker", *sub, item["ref"]], timeout=30)
        parts.append("docker inspect (truncated):\n" + out[:5000])
    elif item["kind"] == "process":
        pid = str(item.get("pid") or item.get("ref"))
        rc, out, _ = run(["ps", "-ww", "-o", "pid,ppid,user,etime,pcpu,rss,args", "-p", pid], timeout=10)
        parts.append("ps:\n" + out[:3000])
        rc, out, _ = run(["lsof", "-a", "-d", "cwd", "-p", pid], timeout=10)
        parts.append("cwd:\n" + out[:800])
    elif path and os.path.isdir(path):
        rc, out, _ = run(["ls", "-la", path], timeout=20)
        parts.append("ls -la (first 60 lines):\n" + "\n".join(out.splitlines()[:60]))
        if is_git_worktree_dir(path) or is_git_repo_dir(path):
            for args in (["remote", "-v"], ["status", "--short", "--branch"], ["log", "-10", "--format=%h %cs %an %s"]):
                rc, out, _ = git(path, *args, timeout=60)
                parts.append("git %s:\n%s" % (" ".join(args), "\n".join(out.splitlines()[:30])))
    elif path and os.path.isfile(path):
        rc, out, _ = run(["ls", "-la", path], timeout=10)
        parts.append(out)
        rc, out, _ = run(["file", path], timeout=10)
        parts.append(out)
    if item["kind"] == "task" and item.get("ref"):
        status = tail_lines(os.path.join(ctx.fm_home, "state", item["ref"] + ".status"), 8)
        parts.append("Recent status lines:\n" + "\n".join(status))
    return "\n\n".join(parts)


ASK_PROMPT = """You help a developer decide what to free on their Mac.
You cannot run commands; judge only from the context below, which was gathered read-only.
Answer in at most 8 short lines:
1. What this is, in plain words.
2. Who or what probably created it, and whether something still uses it.
3. What would be lost if it were removed, and how to recreate it.
4. Your guess: safe to remove / probably safe / not safe - with your confidence.
Say plainly when the context is not enough to tell.

Context:
%s
"""


ALL_SOURCES = (scan_docker, scan_firstmate, scan_git, scan_caches, scan_personal, scan_system)
TAB_SOURCES = {
    "disk": (scan_docker, scan_git, scan_caches, scan_personal, scan_system),
    "firstmate": (scan_docker, scan_firstmate),
}


def scan_report(ctx, tabs, measure, top, min_bytes):
    """One synchronous read-only scan, summarized for firstmate (--scan-json)."""
    sources = []
    for t in tabs:
        for fn in TAB_SOURCES[t]:
            if fn not in sources:
                sources.append(fn)
    inv = Inventory(ctx, sources, measure)
    inv.scan_gen = 1
    inv._scan(1)
    items = [i for i in inv.items.values() if i["tab"] in tabs]
    groups = {}
    for i in items:
        g = groups.setdefault("%s/%s" % (i["tab"], i["group"]), {"count": 0, "bytes": 0})
        g["count"] += 1
        g["bytes"] += i.get("size") or 0
    items.sort(key=lambda i: -(i.get("size") or 0))
    keep = [i for i in items if (i.get("size") or 0) >= min_bytes][:top]
    usage = shutil.disk_usage(ctx.home)
    fields = ("tab", "group", "kind", "label", "path", "ref", "size", "action", "note", "details")
    return {
        "generated_at": now_utc(),
        "measured": measure,
        "volume": {"path": ctx.home, "total": usage.total, "used": usage.used, "free": usage.free},
        "groups": dict(sorted(groups.items(), key=lambda kv: -kv[1]["bytes"])),
        "items": [{k: i.get(k) for k in fields} for i in keep],
        "omitted": len(items) - len(keep),
        "errors": inv.errors,
    }


class AskJobs:
    def __init__(self, ctx):
        self.ctx = ctx
        self.jobs = {}
        self.lock = threading.Lock()

    def start(self, item):
        jid = uuid.uuid4().hex[:12]
        with self.lock:
            self.jobs[jid] = {"state": "running", "item": item["id"], "started": now_utc()}
        threading.Thread(target=self._run, args=(jid, item), daemon=True).start()
        return jid

    def _run(self, jid, item):
        context = gather_context(self.ctx, item)
        model = os.environ.get("FM_DISK_LENS_MODEL", HAIKU_MODEL)
        cmd = ["claude", "-p", "--model", model, "--tools", "", "--strict-mcp-config", "--no-session-persistence"]
        with tempfile.TemporaryDirectory(prefix="fm-disk-lens-ask.") as cwd:
            rc, out, err = run(cmd, cwd=cwd, timeout=240, stdin=ASK_PROMPT % context, env=dict(os.environ))
        with self.lock:
            if rc == 0:
                self.jobs[jid].update(state="done", answer=out.strip(), context=context)
            else:
                self.jobs[jid].update(state="failed", answer=(err or out).strip()[:800], context=context)

    def get(self, jid):
        with self.lock:
            j = self.jobs.get(jid)
            return dict(j) if j else None


def handoff(ctx, item, answer, extra):
    lines = [
        "disk-lens: investigate before freeing - %s" % item["label"],
        "kind=%s path=%s ref=%s" % (item["kind"], item.get("path") or "-", item.get("ref") or "-"),
    ]
    if item.get("size") is not None:
        lines.append("size=%.2f GiB" % (item["size"] / 2**30))
    if extra:
        lines.append("Request: %s" % extra.strip()[:2000])
    if answer:
        lines.append("Haiku first look (a guess, not verified):\n%s" % answer.strip()[:3000])
    body = "\n".join(lines)
    env = dict(os.environ, FM_HOME=ctx.fm_home)
    rc, out, err = run([os.path.join(SELF_DIR, "fm-inbox.sh"), "note", "-"], stdin=body, timeout=60, env=env)
    if rc != 0:
        return 502, {"error": "fm-inbox note failed: %s" % (err or out).strip()[:400]}
    return 200, {"ok": True, "output": out.strip()}


# --------------------------------------------------------------------------
# HTTP


class App:
    def __init__(self, args, token):
        self.ctx = Context(args.home)
        self.token = token
        self.port = None
        self.inv = Inventory(self.ctx)
        self.asks = AskJobs(self.ctx)
        self.procs = ProcGuard(self.ctx, args.watch_pid)
        self.last_seen = time.time()
        self.stop = threading.Event()

    def slot_entry(self, item):
        main = item["details"].get("main_repo")
        if not main:
            slot = treehouse_slot_of(self.ctx, item["path"])
            pools = dict(treehouse_pools(self.ctx)) if slot else {}
            main = pools.get(slot[0]) if slot else None
        if not main:
            return None
        entries, _ = treehouse_status(main)
        for e in entries or []:
            if real(e.get("path") or "") == real(item["path"]):
                return e
        return None

    def git_plan_input(self, item):
        """(slot_entry, refusal): a pool slot must still be listed by
        treehouse so its lease and processes are known before any removal."""
        if item["action"] != "treehouse-slot" and not treehouse_slot_of(self.ctx, item["path"]):
            return None, None
        entry = self.slot_entry(item)
        if entry is None:
            return None, "treehouse does not list this slot, so its lease cannot be checked"
        return entry, None

    def plan(self, item):
        a = item["action"]
        if a in ("git-backup", "treehouse-slot"):
            entry, refusal = self.git_plan_input(item)
            if refusal:
                p = Plan()
                p.refusals.append(refusal)
                return p
            return plan_git(self.ctx, item, entry)
        if a == "trash":
            return plan_trash(self.ctx, item)
        if a == "docker":
            return plan_docker(item)
        p = Plan()
        p.refusals.append("this item has no free action here")
        if item["kind"] == "task":
            p.refusals.append("live task %s: firstmate cleanup owns it" % item.get("ref"))
        return p

    def execute(self, item, mode):
        a = item["action"]
        if mode == "trash":
            if item["kind"] not in ("path", "worktree", "repo") or not item.get("path"):
                return 400, {"error": "Trash applies only to paths"}
            return execute_trash(self.ctx, item)
        if a in ("git-backup", "treehouse-slot"):
            entry, refusal = self.git_plan_input(item)
            if refusal:
                return 409, {"error": "refused", "plan": {"ok": False, "refusals": [refusal], "steps": [], "facts": {}}}
            return execute_git(self.ctx, item, entry)
        if a == "trash":
            return execute_trash(self.ctx, item)
        if a == "docker":
            return execute_docker(item)
        return 409, {"error": "refused", "plan": self.plan(item).as_dict()}


def make_handler(app):
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "fm-disk-lens"

        def log_message(self, fmt, *a):
            pass

        def _send(self, code, body, ctype="application/json"):
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _origin_ok(self):
            allowed = {"%s:%d" % (LOOPBACK, app.port), "localhost:%d" % app.port}
            if self.headers.get("Host") not in allowed:
                return False
            origin = self.headers.get("Origin")
            if origin and origin not in ("http://" + h for h in allowed):
                return False
            return True

        def _token_ok(self, supplied):
            return bool(supplied) and hmac.compare_digest(supplied.encode(), app.token.encode())

        def _guard(self, page=False):
            if not self._origin_ok():
                self._send(403, {"error": "bad host or origin"})
                return False
            if page:
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                ok = self._token_ok((q.get("token") or [""])[0])
            else:
                ok = self._token_ok(self.headers.get("X-Disk-Lens-Token", ""))
            if not ok:
                self._send(403, {"error": "missing or wrong token"})
                return False
            app.last_seen = time.time()
            return True

        def _body(self):
            n = int(self.headers.get("Content-Length") or 0)
            if n > 1_000_000:
                return None
            raw = self.rfile.read(n) if n else b"{}"
            try:
                return json.loads(raw or b"{}")
            except ValueError:
                return None

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            if url.path == "/":
                if not self._guard(page=True):
                    return
                with open(PAGE_FILE, "rb") as f:
                    self._send(200, f.read(), "text/html; charset=utf-8")
                return
            if not self._guard():
                return
            q = urllib.parse.parse_qs(url.query)
            if url.path == "/api/items":
                tab = (q.get("tab") or ["disk"])[0]
                self._send(200, {"items": app.inv.snapshot(tab), "scanning": app.inv.scanning, "errors": app.inv.errors})
            elif url.path == "/api/procs":
                procs = list_processes()
                by_pid = {p["pid"]: p for p in procs}
                me = current_user()
                for p in procs:
                    p["warnings"] = app.procs.warnings(p, by_pid)
                    p["killable"] = p["user"] == me and p["pid"] > 1
                self._send(200, {"procs": procs, "memory": memory_summary()})
            elif url.path.startswith("/api/ask/"):
                j = app.asks.get(url.path.rsplit("/", 1)[1])
                self._send(200 if j else 404, j or {"error": "no such job"})
            elif url.path == "/api/ping":
                self._send(200, {"ok": True})
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            if not self._guard():
                return
            body = self._body()
            if body is None:
                self._send(400, {"error": "bad json body"})
                return
            path = urllib.parse.urlparse(self.path).path
            if path == "/api/quit":
                self._send(200, {"ok": True})
                app.stop.set()
                return
            if path == "/api/rescan":
                app.inv.rescan()
                self._send(200, {"ok": True})
                return
            if path == "/api/kill":
                try:
                    pid = int(body.get("pid"))
                except (TypeError, ValueError):
                    self._send(400, {"error": "pid required"})
                    return
                code, res = app.procs.kill(pid, str(body.get("lstart") or ""), str(body.get("signal") or "TERM"), bool(body.get("ack_warning")))
                self._send(code, res)
                return
            if path == "/api/ask-process":
                try:
                    pid = int(body.get("pid"))
                except (TypeError, ValueError):
                    self._send(400, {"error": "pid required"})
                    return
                item = {"id": "proc-%d" % pid, "kind": "process", "pid": pid, "ref": str(pid), "label": "process %d" % pid, "details": {}}
                self._send(200, {"job": app.asks.start(item)})
                return
            item = app.inv.get(str(body.get("id") or ""))
            if path == "/api/handoff" and body.get("pid"):
                item = {"id": "proc", "kind": "process", "label": "process %s" % body.get("pid"), "ref": str(body.get("pid")), "path": ""}
            if not item:
                self._send(404, {"error": "unknown item id; rescan"})
                return
            if path == "/api/preview":
                if body.get("mode") == "trash":
                    self._send(200, plan_trash(app.ctx, item).as_dict() if item.get("path") else {"ok": False, "refusals": ["no path"], "steps": [], "facts": {}})
                else:
                    self._send(200, app.plan(item).as_dict())
            elif path == "/api/free":
                if body.get("confirm") is not True:
                    self._send(400, {"error": "confirm: true required"})
                    return
                if item["kind"] == "process":
                    self._send(400, {"error": "use /api/kill for processes"})
                    return
                code, res = app.execute(item, body.get("mode"))
                if code == 200:
                    with app.inv.lock:
                        app.inv.items.pop(item["id"], None)
                self._send(code, res)
            elif path == "/api/ask":
                self._send(200, {"job": app.asks.start(item)})
            elif path == "/api/private-size":
                if not item.get("path") or not os.path.isdir(item["path"]):
                    self._send(400, {"error": "no directory to measure"})
                    return

                def measure(it=item):
                    size = private_bytes(it["path"])
                    with app.inv.lock:
                        it["private"] = size

                threading.Thread(target=measure, daemon=True).start()
                self._send(200, {"ok": True})
            elif path == "/api/handoff":
                code, res = handoff(app.ctx, item, str(body.get("answer") or ""), str(body.get("note") or ""))
                self._send(code, res)
            else:
                self._send(404, {"error": "not found"})

    return Handler


def memory_summary():
    out = {}
    rc, mem, _ = run(["sysctl", "-n", "hw.memsize"], timeout=5)
    if rc == 0 and mem.strip().isdigit():
        out["total"] = int(mem.strip())
    rc, sw, _ = run(["sysctl", "-n", "vm.swapusage"], timeout=5)
    if rc == 0:
        out["swap"] = sw.strip()
    rc, vm, _ = run(["vm_stat"], timeout=5)
    if rc == 0:
        page = 4096
        m = re.search(r"page size of (\d+) bytes", vm)
        if m:
            page = int(m.group(1))
        stats = {}
        for line in vm.splitlines()[1:]:
            k, _, v = line.partition(":")
            v = v.strip().rstrip(".")
            if v.isdigit():
                stats[k.strip()] = int(v) * page
        out["free"] = stats.get("Pages free", 0)
        out["compressed"] = stats.get("Pages occupied by compressor", 0)
        out["wired"] = stats.get("Pages wired down", 0)
    return out


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def watchdog(app, watch_pid, idle_minutes):
    while not app.stop.is_set():
        if watch_pid:
            try:
                os.kill(watch_pid, 0)
            except ProcessLookupError:
                app.stop.set()
                break
            except PermissionError:
                pass
        if idle_minutes and time.time() - app.last_seen > idle_minutes * 60:
            app.stop.set()
            break
        app.stop.wait(2)


def main(argv):
    ap = argparse.ArgumentParser(description="disk-lens local server")
    ap.add_argument("--home", required=True)
    ap.add_argument("--token-file")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--bind", default=LOOPBACK)
    ap.add_argument("--watch-pid", type=int, default=0)
    ap.add_argument("--idle-minutes", type=float, default=60)
    ap.add_argument("--url-file")
    ap.add_argument("--no-scan", action="store_true", help="skip the startup scan (tests)")
    ap.add_argument("--scan-json", action="store_true", help="print one read-only scan as JSON and exit; no server")
    ap.add_argument("--tabs", default="disk,firstmate", help="--scan-json: comma list of disk, firstmate")
    ap.add_argument("--no-du", action="store_true", help="--scan-json: skip du sizing (fast; sizes only for docker)")
    ap.add_argument("--top", type=int, default=40, help="--scan-json: items to list")
    ap.add_argument("--min-mb", type=float, default=0, help="--scan-json: smallest item to list")
    args = ap.parse_args(argv)
    if args.scan_json:
        tabs = [t for t in args.tabs.split(",") if t]
        if not tabs or any(t not in TAB_SOURCES for t in tabs):
            print("fm-disk-lens: --tabs takes disk and/or firstmate", file=sys.stderr)
            return 2
        report = scan_report(Context(args.home), tabs, not args.no_du, args.top, int(args.min_mb * 1048576))
        json.dump(report, sys.stdout, indent=1)
        sys.stdout.write("\n")
        return 0
    if not args.token_file:
        print("fm-disk-lens: --token-file is required to serve", file=sys.stderr)
        return 2
    if args.bind != LOOPBACK:
        print("fm-disk-lens: refusing to bind %s; only %s is allowed" % (args.bind, LOOPBACK), file=sys.stderr)
        return 2
    try:
        with open(args.token_file, encoding="utf-8") as f:
            token = f.read().strip()
    except OSError as e:
        print("fm-disk-lens: cannot read token file: %s" % e, file=sys.stderr)
        return 2
    if len(token) < 32:
        print("fm-disk-lens: token must be at least 32 characters", file=sys.stderr)
        return 2
    try:
        os.setsid()  # outlive the launching shell's process group
    except OSError:
        pass
    app = App(args, token)
    httpd = Server((LOOPBACK, args.port), make_handler(app))
    app.port = httpd.server_address[1]
    url = "http://%s:%d/?token=%s" % (LOOPBACK, app.port, token)
    if args.url_file:
        tmp = args.url_file + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(url + "\n")
        os.replace(tmp, args.url_file)
    print("fm-disk-lens: listening on %s:%d" % (LOOPBACK, app.port), flush=True)
    if not args.no_scan:
        app.inv.rescan()
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    threading.Thread(target=watchdog, args=(app, args.watch_pid, args.idle_minutes), daemon=True).start()
    reason = ["quit, idle, or watched process exit"]

    def on_signal(signum, _frame):
        reason[0] = "signal %s" % signal.Signals(signum).name
        app.stop.set()

    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    for s in (signal.SIGTERM, signal.SIGINT):
        signal.signal(s, on_signal)
    app.stop.wait()
    httpd.shutdown()
    print("fm-disk-lens: stopped (%s)" % reason[0], flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
