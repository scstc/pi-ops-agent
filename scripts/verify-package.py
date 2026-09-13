#!/usr/bin/env python3
"""Verify a pi-ops-agent .tar.gz or self-extracting .run package in a stream."""

from __future__ import print_function

import argparse
import gzip
import hashlib
import hmac
from pathlib import Path, PurePosixPath
import sys
import tarfile


MODELS = ("qwen3.5-2b", "qwen3.5-0.8b")
RUN_MARKER = b"__PI_OPS_PAYLOAD_BELOW__\n"
CHUNK_SIZE = 1024 * 1024
MAX_SMALL_FILE = 8 * 1024 * 1024
REQUIRED_FILES = frozenset((
    "install.sh", "uninstall.sh", "env-check.sh", "assets/SYSTEM.md",
    "assets/bin/idle-stop.sh", "assets/bin/pi-ops-verify",
    "assets/extensions/ops-tools.ts", "assets/lib/verify-check.js",
    "bundle/MANIFEST.sha256", "bundle/default-model.txt",
    "bundle/pi-bundle.tar.gz", "bundle/pi-version.txt",
))
EXECUTABLE_SCRIPTS = frozenset((
    "install.sh", "uninstall.sh", "env-check.sh", "assets/bin/idle-stop.sh",
    "assets/bin/pi-ops-verify",
))


class PackageError(Exception):
    pass


def safe_member_name(name):
    """Canonicalize a tar name, rejecting paths unsafe to extract."""
    if not name or "\\" in name or "\x00" in name:
        raise PackageError("unsafe tar member name: {!r}".format(name))
    path = PurePosixPath(name)
    if path.is_absolute() or any(part == ".." for part in path.parts):
        raise PackageError("unsafe tar member path: {!r}".format(name))
    parts = tuple(part for part in path.parts if part not in (".", ""))
    if not parts:
        raise PackageError("unsafe empty tar member path: {!r}".format(name))
    return "/".join(parts)


def resolve_relative_path(parts):
    result = []
    for part in parts:
        if part in ("", "."):
            continue
        if part == "..":
            if not result:
                raise PackageError("link target escapes archive root")
            result.pop()
        else:
            result.append(part)
    if not result:
        raise PackageError("empty link target")
    return "/".join(result)


def resolve_link(source, target, hard_link):
    if not target or "\\" in target or "\x00" in target:
        raise PackageError("unsafe link target: {!r}".format(target))
    target_path = PurePosixPath(target)
    if target_path.is_absolute():
        raise PackageError("absolute link target: {!r}".format(target))
    if hard_link:
        return resolve_relative_path(target_path.parts)
    return resolve_relative_path(PurePosixPath(source).parent.parts + target_path.parts)


def bundle_relative(name):
    return name[len("bundle/"):]


def small_file(member_file, size, label):
    if size > MAX_SMALL_FILE:
        raise PackageError("{} is too large".format(label))
    data = member_file.read(size)
    if len(data) != size:
        raise PackageError("unexpected end of {}".format(label))
    return data


class DigestReader(object):
    """A bounded reader which hashes bytes while an embedded tar is parsed."""

    def __init__(self, source, size, label):
        self.source = source
        self.remaining = size
        self.label = label
        self.hasher = hashlib.sha256()
        self.prefix = b""

    def read(self, size=-1):
        if size is None or size < 0 or size > self.remaining:
            size = self.remaining
        data = self.source.read(size)
        if data:
            self.remaining -= len(data)
            self.hasher.update(data)
            if len(self.prefix) < 4:
                self.prefix += data[:4 - len(self.prefix)]
        return data

    def drain(self):
        while self.remaining:
            data = self.read(min(CHUNK_SIZE, self.remaining))
            if not data:
                raise PackageError("unexpected end of {}".format(self.label))
        return self.hasher.hexdigest(), self.prefix


def hash_member(member_file, size, label):
    return DigestReader(member_file, size, label).drain()


def hash_script(member_file, size, label):
    if size > MAX_SMALL_FILE:
        raise PackageError("{} is too large".format(label))
    reader = DigestReader(member_file, size, label)
    previous_cr = False
    while reader.remaining:
        block = reader.read(min(CHUNK_SIZE, reader.remaining))
        if not block:
            raise PackageError("unexpected end of {}".format(label))
        if b"\r\n" in block or (previous_cr and block.startswith(b"\n")):
            raise PackageError("script has CRLF line endings: {}".format(label))
        previous_cr = block.endswith(b"\r")
    return reader.hasher.hexdigest()


def parse_manifest(data):
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError:
        raise PackageError("bundle/MANIFEST.sha256 is not UTF-8")
    manifest = {}
    for line in lines:
        if not line:
            continue
        if len(line) < 67 or line[64:66] not in ("  ", " *"):
            raise PackageError("malformed MANIFEST.sha256 entry: {!r}".format(line))
        digest, filename = line[:64], line[66:]
        if any(char not in "0123456789abcdefABCDEF" for char in digest):
            raise PackageError("invalid SHA-256 in MANIFEST.sha256: {!r}".format(digest))
        try:
            normalized = safe_member_name(filename)
        except PackageError:
            raise PackageError("unsafe MANIFEST.sha256 filename: {!r}".format(filename))
        if normalized in manifest:
            raise PackageError("duplicate MANIFEST.sha256 filename: {}".format(normalized))
        manifest[normalized] = digest.lower()
    if not manifest:
        raise PackageError("bundle/MANIFEST.sha256 is empty")
    return manifest


def member_names_from_inner(member_file, size, mode, label):
    reader = DigestReader(member_file, size, label)
    names, links = set(), []
    try:
        with tarfile.open(fileobj=reader, mode=mode) as archive:
            for member in archive:
                if member.isdir() and member.name in (".", "./"):
                    # llama's archive is intentionally made with `tar -C bin .`.
                    continue
                name = safe_member_name(member.name)
                if member.isdev():
                    raise PackageError("unsafe member in {}: {}".format(label, name))
                if member.isreg() or member.isdir():
                    names.add(name)
                elif member.issym() or member.islnk():
                    links.append((name, member.linkname, member.islnk()))
                else:
                    raise PackageError("unsupported member in {}: {}".format(label, name))
        targets = {source: resolve_link(source, target, hard_link)
                   for source, target, hard_link in links}
        for source, target in targets.items():
            visited = {source}
            resolved = target
            while resolved in targets:
                if resolved in visited:
                    raise PackageError("link cycle in {}: {}".format(label, source))
                visited.add(resolved)
                resolved = targets[resolved]
            if resolved not in names:
                raise PackageError("link target missing in {}: {} -> {}".format(label, source, target))
        names.update(targets)
    except (OSError, tarfile.TarError, EOFError) as exc:
        raise PackageError("invalid embedded archive {}: {}".format(label, exc))
    digest, _ = reader.drain()
    return names, digest


def has_suffix(names, suffix):
    return any(name == suffix or name.endswith("/" + suffix) for name in names)


def validate_node_archive(member_file, size, label):
    names, digest = member_names_from_inner(member_file, size, "r|xz", label)
    needed = ("bin/node", "lib/libstdc++.so.6", "lib/libgcc_s.so.1")
    missing = [item for item in needed if not has_suffix(names, item)]
    if missing:
        raise PackageError("{} missing runtime file(s): {}".format(label, ", ".join(missing)))
    return digest


def validate_llama_archive(member_file, size, label):
    names, digest = member_names_from_inner(member_file, size, "r|gz", label)
    needed = ("llama-server", "libgomp.so.1")
    missing = [item for item in needed if not has_suffix(names, item)]
    if missing:
        raise PackageError("{} missing runtime file(s): {}".format(label, ", ".join(missing)))
    return digest


def payload_offset(run_file):
    total = 0
    while total <= 4 * 1024 * 1024:
        line = run_file.readline()
        if not line:
            break
        total += len(line)
        if line == RUN_MARKER:
            offset = run_file.tell()
            if run_file.read(2) != b"\x1f\x8b":
                raise PackageError(".run payload after marker is not gzip")
            run_file.seek(offset)
            return offset
    raise PackageError(".run payload marker is missing or header exceeds 4 MiB")


def open_package(path):
    raw = path.open("rb")
    if path.name.endswith(".tar.gz"):
        return raw, None
    if path.suffix == ".run":
        try:
            return raw, payload_offset(raw)
        except Exception:
            raw.close()
            raise
    raw.close()
    raise PackageError("package must end in .tar.gz or .run")


def verify(path, model):
    if not path.is_file():
        raise PackageError("package not found: {}".format(path))
    required, seen = set(REQUIRED_FILES), set()
    bundle_hashes, manifest = {}, None
    ggufs, default_model = [], None
    node_archives, llama_archives = 0, 0

    raw, offset = open_package(path)
    archive = None
    compressed = None
    try:
        if offset is not None:
            raw.seek(offset)
        try:
            # tarfile's r|gz reader can stop at the end-of-tar marker without
            # consuming the gzip trailer.  Drain GzipFile explicitly so a .run
            # truncated after a valid tar body still fails verification.
            compressed = gzip.GzipFile(fileobj=raw, mode="rb")
            archive = tarfile.open(fileobj=compressed, mode="r|")
            for member in archive:
                name = safe_member_name(member.name)
                if name in seen:
                    raise PackageError("duplicate tar member: {}".format(name))
                seen.add(name)
                if member.issym() or member.islnk() or member.isdev():
                    raise PackageError("unsafe non-file tar member: {}".format(name))
                if member.isdir():
                    continue
                if not member.isreg():
                    raise PackageError("unsupported tar member type: {}".format(name))
                member_file = archive.extractfile(member)
                if member_file is None:
                    raise PackageError("cannot read tar member: {}".format(name))

                if name in EXECUTABLE_SCRIPTS:
                    if (member.mode & 0o111) == 0:
                        raise PackageError("script is not executable: {}".format(name))
                    digest = hash_script(member_file, member.size, name)
                    if name.startswith("bundle/"):
                        bundle_hashes[bundle_relative(name)] = digest
                    continue
                if name == "bundle/MANIFEST.sha256":
                    manifest = parse_manifest(small_file(member_file, member.size, name))
                    continue
                if name == "bundle/default-model.txt":
                    default_model = small_file(member_file, member.size, name)
                    bundle_hashes[bundle_relative(name)] = hashlib.sha256(default_model).hexdigest()
                    continue
                if name.startswith("bundle/node-v") and name.endswith("-linux-x64.tar.xz"):
                    node_archives += 1
                    bundle_hashes[bundle_relative(name)] = validate_node_archive(member_file, member.size, name)
                    continue
                if name.startswith("bundle/llama-") and name.endswith(".tar.gz"):
                    llama_archives += 1
                    bundle_hashes[bundle_relative(name)] = validate_llama_archive(member_file, member.size, name)
                    continue

                digest, prefix = hash_member(member_file, member.size, name)
                if name.startswith("bundle/"):
                    relative = bundle_relative(name)
                    bundle_hashes[relative] = digest
                    if name.endswith(".gguf"):
                        ggufs.append((relative, prefix))
            archive.close()
            archive = None
            while compressed.read(CHUNK_SIZE):
                pass
        except (OSError, tarfile.TarError, EOFError) as exc:
            raise PackageError("invalid or truncated gzip tar payload: {}".format(exc))
    finally:
        if archive is not None:
            archive.close()
        if compressed is not None:
            compressed.close()
        raw.close()

    missing = sorted(required - seen)
    if missing:
        raise PackageError("missing required file(s): " + ", ".join(missing))
    if manifest is None:
        raise PackageError("missing bundle/MANIFEST.sha256")
    expected_gguf = model + ".gguf"
    if len(ggufs) != 1 or ggufs[0][0] != expected_gguf:
        found = ", ".join(name for name, _ in ggufs) or "none"
        raise PackageError("expected exactly bundle/{}; found: {}".format(expected_gguf, found))
    if ggufs[0][1] != b"GGUF":
        raise PackageError("bundle/{} does not start with GGUF magic".format(expected_gguf))
    if default_model != (model + "\n").encode("ascii"):
        raise PackageError("bundle/default-model.txt must be exactly {!r} followed by LF".format(model))
    if node_archives != 1 or llama_archives != 1:
        raise PackageError("expected one node and one llama runtime archive; found node={}, llama={}".format(node_archives, llama_archives))
    if set(manifest) != set(bundle_hashes):
        details = []
        unlisted = sorted(set(bundle_hashes) - set(manifest))
        manifest_only = sorted(set(manifest) - set(bundle_hashes))
        if unlisted:
            details.append("unlisted bundle file(s): " + ", ".join(unlisted))
        if manifest_only:
            details.append("manifest-only file(s): " + ", ".join(manifest_only))
        raise PackageError("; ".join(details))
    for name, digest in bundle_hashes.items():
        if not hmac.compare_digest(manifest[name], digest):
            raise PackageError("SHA-256 mismatch: bundle/{}".format(name))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path, help="package .tar.gz or self-extracting .run")
    parser.add_argument("--model", required=True, choices=MODELS, help="model contained in the package")
    arguments = parser.parse_args(argv)
    try:
        verify(arguments.package, arguments.model)
    except PackageError as exc:
        print("[verify-package] FAILED: {}".format(exc), file=sys.stderr)
        return 1
    print("[verify-package] OK: {} ({})".format(arguments.package, arguments.model))
    return 0


if __name__ == "__main__":
    sys.exit(main())
