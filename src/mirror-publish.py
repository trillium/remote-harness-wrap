#!/usr/bin/env python3
"""Publish a staged tree into a destination, one atomic replace per path.

Bytes are written outside the destination and then os.replace'd into place.
A crash leaves each destination path as the previous complete file, or absent
when the path is new. The destination is never written in place.
"""
import argparse
import os
import shutil
import stat
import sys
import tempfile


def rel_of(path, root):
    rel = os.path.relpath(path, root)
    if rel == ".":
        return ""
    return rel


def collect(stage):
    """Return (rel, kind) for every path under stage. kind is dir, file, or link."""
    items = []
    for dirpath, dirnames, filenames in os.walk(stage, followlinks=False):
        rel_dir = rel_of(dirpath, stage)
        kept = []
        for name in dirnames:
            full = os.path.join(dirpath, name)
            rel = name if not rel_dir else os.path.join(rel_dir, name)
            if os.path.islink(full):
                items.append((rel, "link"))
            else:
                kept.append(name)
                items.append((rel, "dir"))
        dirnames[:] = kept
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = name if not rel_dir else os.path.join(rel_dir, name)
            if os.path.islink(full):
                items.append((rel, "link"))
            elif stat.S_ISREG(os.lstat(full).st_mode):
                items.append((rel, "file"))
    return items


def same_device_tmp(dest_root):
    parent = os.path.dirname(dest_root) or "/"
    os.makedirs(parent, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".rw-publish-", dir=parent)
    os.close(fd)
    return tmp


def place_file(src, dest, dest_root):
    mode = stat.S_IMODE(os.lstat(src).st_mode)
    tmp = same_device_tmp(dest_root)
    try:
        with open(src, "rb") as src_fh, open(tmp, "wb") as dst_fh:
            shutil.copyfileobj(src_fh, dst_fh, length=1024 * 1024)
        os.chmod(tmp, mode)
        os.replace(tmp, dest)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def place_link(src, dest, dest_root):
    target = os.readlink(src)
    tmp = same_device_tmp(dest_root)
    os.unlink(tmp)
    try:
        os.symlink(target, tmp)
        os.replace(tmp, dest)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def ensure_cleared(path):
    if os.path.lexists(path) and os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    elif os.path.lexists(path):
        os.unlink(path)


def publish(stage, dest, delete, delete_list):
    os.makedirs(dest, exist_ok=True)
    items = collect(stage)
    seen = set()
    for rel, kind in items:
        if not rel or rel.startswith("/") or ".." in rel.split("/"):
            raise SystemExit("refusing unsafe relative path")
        seen.add(rel)
        target = os.path.join(dest, rel)
        parent = os.path.dirname(target)
        if parent and not os.path.isdir(parent):
            os.makedirs(parent, exist_ok=True)
        src = os.path.join(stage, rel)
        if kind == "dir":
            if os.path.lexists(target) and not (
                os.path.isdir(target) and not os.path.islink(target)
            ):
                os.unlink(target)
            os.makedirs(target, exist_ok=True)
            mode = stat.S_IMODE(os.lstat(src).st_mode)
            try:
                os.chmod(target, mode)
            except OSError:
                pass
            continue
        if os.path.lexists(target) and os.path.isdir(target) and not os.path.islink(target):
            shutil.rmtree(target)
        if kind == "link":
            place_link(src, target, dest)
        else:
            place_file(src, target, dest)

    doomed = []
    if delete:
        for dirpath, dirnames, filenames in os.walk(dest, followlinks=False):
            rel_dir = rel_of(dirpath, dest)
            kept = []
            for name in list(dirnames):
                full = os.path.join(dirpath, name)
                rel = name if not rel_dir else os.path.join(rel_dir, name)
                if os.path.islink(full):
                    if rel not in seen:
                        doomed.append(full)
                else:
                    kept.append(name)
            dirnames[:] = kept
            for name in filenames:
                rel = name if not rel_dir else os.path.join(rel_dir, name)
                if rel not in seen:
                    doomed.append(os.path.join(dirpath, name))
            if rel_dir and rel_dir not in seen:
                doomed.append(dirpath)
    for rel in delete_list:
        rel = rel.strip("\n")
        if not rel or rel.startswith("/") or ".." in rel.split("/"):
            raise SystemExit("refusing unsafe delete path")
        doomed.append(os.path.join(dest, rel))

    # Deeper paths first so a file goes before its parent directory.
    doomed = sorted(set(doomed), key=lambda p: p.count(os.sep), reverse=True)
    for path in doomed:
        if not os.path.lexists(path):
            continue
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.unlink(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", required=True)
    parser.add_argument("--dest", required=True)
    parser.add_argument("--delete", action="store_true")
    parser.add_argument("--delete-list", default="")
    args = parser.parse_args()
    stage = os.path.abspath(args.stage)
    dest = os.path.abspath(args.dest)
    if stage == dest or dest.startswith(stage + os.sep) or stage.startswith(dest + os.sep):
        raise SystemExit("stage and dest must be separate trees")
    extra = []
    if args.delete_list:
        with open(args.delete_list, "r", encoding="utf-8") as fh:
            extra = [line for line in fh.read().splitlines() if line]
    publish(stage, dest, args.delete, extra)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(1)
