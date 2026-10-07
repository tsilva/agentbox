#!/usr/bin/env python3
"""Optional staged editing, using only Python's standard library."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys


def files(root):
    result = {}
    for directory, dirs, names in os.walk(root, followlinks=False):
        for name in dirs + names:
            path = Path(directory) / name
            if path.is_symlink():
                raise ValueError("staged workspaces cannot contain symlinks")
        for name in names:
            path = Path(directory) / name
            if not path.is_file():
                raise ValueError("staged workspace contains a special file")
            result[str(path.relative_to(root))] = path
    return result


def fingerprint(path):
    if not path.exists():
        return None
    if path.is_symlink() or not path.is_file():
        raise ValueError("source file is not a regular file")
    return [hashlib.sha256(path.read_bytes()).hexdigest(), stat.S_IMODE(path.stat().st_mode)]


def stage(source, session):
    source = source.resolve(strict=True)
    top = subprocess.check_output(["git", "-C", str(source), "rev-parse", "--show-toplevel"], text=True).strip()
    if source != Path(top).resolve():
        raise ValueError("--staged requires the Git repository root")
    paths = subprocess.check_output(["git", "-C", str(source), "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    baseline = {}
    workspace = session / "workspace"
    workspace.mkdir(mode=0o700)
    for raw in paths.split(b"\0"):
        if not raw:
            continue
        relative = Path(os.fsdecode(raw))
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("unsafe Git path")
        if any(part == ".git" for part in relative.parts):
            continue
        if relative.name.startswith(".env") or relative.suffix.lower() in (".pem", ".key"):
            continue
        path = source / relative
        if path.is_symlink() or path.resolve() != path or not path.is_file():
            continue
        dest = workspace / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        before = fingerprint(path)
        shutil.copy2(path, dest)
        if fingerprint(path) != before or fingerprint(dest) != before:
            raise ValueError("source changed while staging")
        baseline[str(relative)] = before
    identity = source.stat()
    metadata = {"source": str(source), "identity": [identity.st_dev, identity.st_ino], "files": baseline}
    (session / "source").write_text(str(source))
    (session / "baseline").write_text(json.dumps(metadata))
    os.chmod(session / "baseline", 0o600)


def directory_fd(root_fd, parts):
    fd = os.dup(root_fd)
    try:
        for part in parts:
            try:
                os.mkdir(part, mode=0o755, dir_fd=fd)
            except FileExistsError:
                pass
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except Exception:
        os.close(fd)
        raise


def apply(session):
    metadata = json.loads((session / "baseline").read_text())
    source = Path(metadata["source"])
    if source.resolve(strict=True) != source:
        raise ValueError("source path is no longer canonical")
    identity = source.stat()
    if [identity.st_dev, identity.st_ino] != metadata["identity"]:
        raise ValueError("source checkout identity changed")
    workspace = session / "workspace"
    current = files(workspace)
    baseline = metadata["files"]
    changes = []
    # Preflight every change before applying anything. Protected names cannot be
    # introduced by an agent and symlink parents cannot redirect host writes.
    for relative in sorted(set(current) | set(baseline)):
        path = Path(relative)
        if path.is_absolute() or ".." in path.parts or ".git" in path.parts or path.name.startswith(".env") or path.suffix.lower() in (".pem", ".key"):
            raise ValueError("protected or unsafe staged path")
        new = fingerprint(current[relative]) if relative in current else None
        old = baseline.get(relative)
        if new == old:
            continue
        target = source / relative
        if target.resolve() != target or fingerprint(target) != old:
            raise ValueError("source changed or contains a symlink: " + relative)
        changes.append((relative, new))
    root_fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for relative, new in changes:
            path = Path(relative)
            fd = directory_fd(root_fd, path.parts[:-1])
            try:
                if new is None:
                    os.unlink(path.name, dir_fd=fd)
                else:
                    data = current[relative].read_bytes()
                    # Safe directory handles prevent an ancestor rename/symlink
                    # from redirecting the write during apply.
                    tmp = ".agentbox-apply-" + os.urandom(12).hex()
                    out = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, new[1], dir_fd=fd)
                    try:
                        with os.fdopen(out, "wb") as stream:
                            stream.write(data)
                            os.fchmod(stream.fileno(), new[1])
                        os.replace(tmp, path.name, src_dir_fd=fd, dst_dir_fd=fd)
                    finally:
                        try:
                            os.unlink(tmp, dir_fd=fd)
                        except FileNotFoundError:
                            pass
                print(("delete " if new is None else "write  ") + relative)
            finally:
                os.close(fd)
    finally:
        os.close(root_fd)
    print("Applied %d file changes" % len(changes))
    shutil.rmtree(session)


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "stage":
        stage(Path(sys.argv[2]), Path(sys.argv[3]))
    elif len(sys.argv) == 3 and sys.argv[1] == "apply":
        apply(Path(sys.argv[2]))
    else:
        raise ValueError("invalid workspace command")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as exc:
        print("agentbox workspace: " + str(exc), file=sys.stderr)
        sys.exit(1)
