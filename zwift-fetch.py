#!/usr/bin/env python3
"""Keep a Zwift install up to date from Zwift's own servers.

Zwift's launcher normally does this, but under Wine the current launcher
exits before it gets that far. This does the same job: it reads the
version file the launcher reads, then the manifest that names, and fetches
every file whose size differs from the manifest's, checking the size and
CRC32 of each download before it replaces anything.

    zwift-fetch.py [DIR]            fetch whatever is missing or out of date
    zwift-fetch.py --check [DIR]    only say what that would be
    zwift-fetch.py --verify [DIR]   checksum every file
    zwift-fetch.py --repair [DIR]   checksum, and fetch again what is wrong

DIR is the Zwift folder, by default the one in the Wine prefix next to this
script. Exit status: 0 all is well; 1 the manifest could not be read, or
DIR does not exist; 2 some downloads failed; 3 (--check) there are files
to fetch; 4 (--verify) some files are corrupt.
"""

import argparse
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zlib
from collections import namedtuple
from concurrent.futures import ThreadPoolExecutor, as_completed

# ZWIFT_CDN points it elsewhere, for tests
BASE = os.environ.get("ZWIFT_CDN", "https://cdn.zwift.com/gameassets/Zwift_Updates_Root")
VERSION_FILE = BASE + "/Zwift_ver_cur.xml"
DEFAULT_DIR = os.path.join(
    os.path.dirname(os.path.realpath(__file__)),
    "prefix", "drive_c", "Program Files (x86)", "Zwift",
)
WORKERS = 8
ATTEMPTS = 3
CHUNK = 1 << 16
HEADERS = {"User-Agent": "Mozilla/5.0"}

# path: as the manifest writes it (backslashes); length: bytes;
# checksum: CRC32 as a signed 32-bit integer, or None
Entry = namedtuple("Entry", "path length checksum")


class ManifestError(Exception):
    pass


def fetch(url, timeout=60):
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS),
                                timeout=timeout) as response:
        return response.read()


def signed(crc):
    """The manifest's checksums are CRC32 read as a signed 32-bit integer."""
    crc &= 0xFFFFFFFF
    return crc - (1 << 32) if crc >= (1 << 31) else crc


def crc_of_file(path):
    crc = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(CHUNK), b""):
            crc = zlib.crc32(chunk, crc)
    return signed(crc)


def local_path(directory, path):
    """Where a manifest path goes. A path that would leave the directory is
    refused: the manifest comes over the network."""
    parts = [p for p in path.replace("\\", "/").split("/") if p not in ("", ".")]
    if not parts or ".." in parts or ":" in parts[0]:
        raise ManifestError("refusing manifest path {!r}".format(path))
    return os.path.join(directory, *parts)


def url_for(folder, path):
    quoted = "/".join(urllib.parse.quote(p) for p in path.replace("\\", "/").split("/"))
    return "{}/{}/{}".format(BASE, folder, quoted)


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if abs(n) < 1024 or unit == "GiB":
            return "{:.1f} {}".format(n, unit)
        n /= 1024.0


def read_manifest(directory):
    """The current version, the folder its files are in, and its entries."""
    try:
        version = ET.fromstring(fetch(VERSION_FILE))
        name = version.get("manifest")
        if not name:
            raise ManifestError("Zwift_ver_cur.xml names no manifest")
        manifest = ET.fromstring(fetch(BASE + "/" + name))
    except (urllib.error.URLError, OSError) as e:
        raise ManifestError("cannot reach Zwift's servers: {}".format(e))
    except ET.ParseError as e:
        raise ManifestError("unreadable manifest: {}".format(e))

    folder = manifest.get("folder")
    if not folder:
        raise ManifestError("the manifest names no folder")
    entries = []
    for f in manifest.iter("file"):
        path = f.findtext("path")
        if not path:
            continue
        local_path(directory, path)             # refuse unsafe paths up front
        try:
            length = int(f.findtext("length") or 0)
        except ValueError:
            length = 0
        try:
            checksum = int(f.findtext("checksum"))
        except (TypeError, ValueError):
            checksum = None
        entries.append(Entry(path, length, checksum))
    return version.get("sversion"), folder, entries


def download(folder, directory, entry):
    """Fetch one file into place. Returns (bytes written, error or None)."""
    target = local_path(directory, entry.path)
    temporary = target + ".part"
    os.makedirs(os.path.dirname(target), exist_ok=True)
    error = None
    for attempt in range(ATTEMPTS):
        if attempt:
            time.sleep(attempt)
        try:
            crc = written = 0
            request = urllib.request.Request(url_for(folder, entry.path), headers=HEADERS)
            with urllib.request.urlopen(request, timeout=120) as response, \
                    open(temporary, "wb") as out:
                for chunk in iter(lambda: response.read(CHUNK), b""):
                    out.write(chunk)
                    crc = zlib.crc32(chunk, crc)
                    written += len(chunk)
        except (urllib.error.URLError, OSError) as e:
            error = "{}: {}".format(type(e).__name__, e)
            continue
        if entry.length and written != entry.length:
            error = "got {} bytes, expected {}".format(written, entry.length)
        elif entry.checksum is not None and signed(crc) != entry.checksum:
            error = "checksum {}, expected {}".format(signed(crc), entry.checksum)
        else:
            os.replace(temporary, target)
            return written, None
    try:
        os.remove(temporary)
    except OSError:
        pass
    return 0, error


def download_all(folder, directory, entries):
    """Fetch the entries in parallel, with progress. Returns the failures."""
    done = got = 0
    failures = []
    started = time.time()
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = {pool.submit(download, folder, directory, e): e for e in entries}
        for future in as_completed(futures):
            written, error = future.result()
            done += 1
            got += written
            if error:
                failures.append((futures[future].path, error))
            if done % 50 == 0 or done == len(entries):
                rate = got / max(time.time() - started, 0.001)
                print("  {}/{}  {}  {}/s  {} failed".format(
                    done, len(entries), human(got), human(rate), len(failures)), flush=True)
    return failures


def corrupt_files(directory, entries):
    """Checksum every local file the manifest has a checksum for."""
    present = [e for e in entries
               if e.checksum is not None and os.path.isfile(local_path(directory, e.path))]
    print("Checksumming {} files...".format(len(present)), flush=True)

    def check(entry):
        path = local_path(directory, entry.path)
        try:
            if os.path.getsize(path) != entry.length:
                return entry, "size {}, expected {}".format(os.path.getsize(path), entry.length)
            if crc_of_file(path) != entry.checksum:
                return entry, "checksum mismatch"
        except OSError as e:
            return entry, "unreadable: {}".format(e)
        return None

    bad = []
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for n, result in enumerate(pool.map(check, present), 1):
            if result:
                bad.append(result)
            if n % 2000 == 0:
                print("  {}/{}".format(n, len(present)), flush=True)
    return bad


def outdated(directory, entries):
    """Files missing or of the wrong size: what a launcher would fetch."""
    stale = []
    for e in entries:
        path = local_path(directory, e.path)
        if not (os.path.isfile(path) and os.path.getsize(path) == e.length):
            stale.append(e)
    return stale


def report(failures, one, many):
    print("{} {}:".format(len(failures), one if len(failures) == 1 else many))
    for path, why in failures[:20]:
        print("  {}  ({})".format(path, why))
    if len(failures) > 20:
        print("  ... and {} more".format(len(failures) - 20))


def main():
    parser = argparse.ArgumentParser(
        description="Keep a Zwift install up to date from Zwift's servers.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true",
                      help="only report what is missing or out of date (exit 3 if anything is)")
    mode.add_argument("--verify", action="store_true",
                      help="checksum every file (exit 4 if any is corrupt)")
    mode.add_argument("--repair", action="store_true",
                      help="checksum every file and fetch the corrupt ones again")
    parser.add_argument("directory", nargs="?", default=DEFAULT_DIR,
                        help="the Zwift folder (default: the one in ./prefix)")
    args = parser.parse_args()

    if not os.path.isdir(args.directory):
        print("No Zwift folder at {}".format(args.directory), file=sys.stderr)
        return 1
    try:
        version, folder, entries = read_manifest(args.directory)
    except ManifestError as e:
        print(e, file=sys.stderr)
        return 1
    print("Zwift {}: {} files, {}".format(
        version, len(entries), human(sum(e.length for e in entries))))
    print("in {}".format(args.directory))

    if args.verify or args.repair:
        bad = corrupt_files(args.directory, entries)
        if not bad:
            print("Every file matches its checksum.")
            return 0
        report([(e.path, why) for e, why in bad], "file is corrupt", "files are corrupt")
        if args.verify:
            print("zwift-fetch.py --repair fetches them again.")
            return 4
        todo = [e for e, _ in bad]
    else:
        # sizes only: checksumming 5 GB before every start would take minutes
        todo = outdated(args.directory, entries)
        print("{} to fetch ({})".format(len(todo), human(sum(e.length for e in todo))))
        if args.check:
            for e in todo[:40]:
                print("  {}".format(e.path))
            if len(todo) > 40:
                print("  ... and {} more".format(len(todo) - 40))
            return 3 if todo else 0
        if not todo:
            return 0

    failures = download_all(folder, args.directory, todo)
    if failures:
        report(failures, "file failed", "files failed")
        print("Run it again to retry them; finished files are kept.")
        return 2
    print("Done.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nInterrupted. Run it again to carry on.", file=sys.stderr)
        sys.exit(130)
