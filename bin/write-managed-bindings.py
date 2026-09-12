#!/usr/bin/env python3
"""Install or remove this plugin's managed keybind block in bindings.lua.

The Omarchy shell plugin runs this as a short-lived, supervised child process
with a closed environment and a fixed argument vector. It receives the block
body as argv[1] (an empty string removes the block) and never reads anything
else from the environment.

The transaction is intentionally conservative:

  * every path component down to ~/.config/hypr is opened with O_NOFOLLOW and
    O_DIRECTORY, so a symlinked or swapped ancestor cannot redirect the write;
  * each opened directory must be non-group/other-writable, and the home
    directory and everything below it must be owned by the effective user;
  * the target file is read through a file descriptor and its identity
    (device, inode, mtime, size) is recorded;
  * the replacement is written to a fresh O_EXCL temp file in the same
    directory, fsync'd, then renamed into place with renameat semantics;
  * the identity is re-checked immediately before the rename, so a concurrent
    edit aborts the transaction instead of being overwritten.

Exit codes:
  0  updated, or already current
  2  refused (unsafe path, ownership, mode, or non-UTF-8 content)
  3  refused because bindings.lua changed concurrently; the caller may retry
  4  usage error
"""

import os
import pwd
import stat
import sys

START = "-- BEGIN audio-switcher (managed, do not edit)"
END = "-- END audio-switcher (managed, do not edit)"
TARGET_NAME = "bindings.lua"
MAX_BLOCK_BYTES = 64 * 1024

_DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW


def refuse(code, message):
    sys.stderr.write("audio-switcher: " + message + "\n")
    raise SystemExit(code)


def open_checked_dir(path, parent_fd=None, must_own=True):
    try:
        fd = os.open(path, _DIR_FLAGS, dir_fd=parent_fd)
    except OSError as exc:
        refuse(2, "cannot open %r without following links: %s" % (path, exc.strerror))
    info = os.fstat(fd)
    if info.st_mode & 0o022:
        os.close(fd)
        refuse(2, "%r is group- or other-writable" % path)
    if must_own and info.st_uid != os.geteuid():
        os.close(fd)
        refuse(2, "%r is not owned by the current user" % path)
    return fd


def bind_target_dir():
    """Return an fd for ~/.config/hypr, opened without following any link."""
    home = pwd.getpwuid(os.geteuid()).pw_dir
    if not home.startswith("/"):
        refuse(2, "home directory is not absolute")
    parts = [part for part in home.split("/") if part]
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for index, part in enumerate(parts):
            # The home directory and everything below must belong to the user;
            # ancestors above it (e.g. /home) only have to be unwritable by
            # anyone else, which the group/other-writable check covers.
            nxt = open_checked_dir(part, parent_fd=fd, must_own=(index == len(parts) - 1))
            os.close(fd)
            fd = nxt
        for part in (".config", "hypr"):
            nxt = open_checked_dir(part, parent_fd=fd, must_own=True)
            os.close(fd)
            fd = nxt
    except BaseException:
        os.close(fd)
        raise
    return fd


def read_current(dir_fd):
    """Return (identity, text, mode) for bindings.lua, or (None, "", 0644)."""
    try:
        target = os.open(TARGET_NAME, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=dir_fd)
    except FileNotFoundError:
        return None, "", 0o644
    except OSError as exc:
        refuse(2, "cannot open %s: %s" % (TARGET_NAME, exc.strerror))
    try:
        info = os.fstat(target)
        if not stat.S_ISREG(info.st_mode):
            refuse(2, "%s is not a regular file" % TARGET_NAME)
        if info.st_uid != os.geteuid():
            refuse(2, "%s is not owned by the current user" % TARGET_NAME)
        if info.st_mode & 0o002:
            refuse(2, "%s is world-writable" % TARGET_NAME)
        chunks = []
        while True:
            chunk = os.read(target, 65536)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        os.close(target)
    data = b"".join(chunks)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        refuse(2, "%s is not valid UTF-8" % TARGET_NAME)
    identity = (info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size)
    return identity, text, stat.S_IMODE(info.st_mode)


def render(current, block):
    """Return `current` with the managed block replaced by `block`."""
    start = current.find(START)
    end = current.find(END)
    head, tail = current, ""
    if start != -1 and end != -1 and end > start:
        head = current[:start]
        tail = current[end + len(END):]
    head = head.rstrip()
    tail = tail.lstrip()
    if block:
        return head + "\n\n" + START + "\n" + block + "\n" + END + "\n" + (("\n" + tail) if tail else "")
    return ((head + "\n") if head else "") + ((tail + "\n") if tail else "")


def write_all(fd, payload):
    view = memoryview(payload)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def main():
    if len(sys.argv) != 2:
        refuse(4, "usage: write-managed-bindings.py <block>")
    block = sys.argv[1]
    if len(block.encode("utf-8")) > MAX_BLOCK_BYTES:
        refuse(2, "managed block exceeds %d bytes" % MAX_BLOCK_BYTES)

    dir_fd = bind_target_dir()
    try:
        identity, current, mode = read_current(dir_fd)
        updated = render(current, block)
        if updated == current:
            return 0

        tmp_name = ".bindings.lua.audio-switcher.%d" % os.getpid()
        tmp_fd = os.open(
            tmp_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
            dir_fd=dir_fd,
        )
        try:
            write_all(tmp_fd, updated.encode("utf-8"))
            os.fchmod(tmp_fd, mode)
            os.fsync(tmp_fd)
        finally:
            os.close(tmp_fd)

        try:
            now = os.stat(TARGET_NAME, dir_fd=dir_fd, follow_symlinks=False)
            current_identity = (now.st_dev, now.st_ino, now.st_mtime_ns, now.st_size)
        except FileNotFoundError:
            current_identity = None
        if current_identity != identity:
            os.unlink(tmp_name, dir_fd=dir_fd)
            refuse(3, "%s changed while updating; retry" % TARGET_NAME)

        os.replace(tmp_name, TARGET_NAME, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        os.fsync(dir_fd)
        return 0
    finally:
        os.close(dir_fd)


if __name__ == "__main__":
    sys.exit(main())
