#!/usr/bin/env python3
"""Merge selected models' PAT URLs and official MD5 sidecars into pats.json."""

import argparse
import concurrent.futures
import json
import re
import subprocess
import urllib.parse
from html.parser import HTMLParser
from pathlib import Path


ARCHIVE = "https://archive.synology.com/download/Os/DSM"
RELEASES = (
    "7.2-64570", "7.2.1-69057", "7.2.2-72806", "7.3-81180",
    "7.3.1-86003", "7.3.2-86009", "7.4-90075", "7.4.1-90080",
)


class PatLinks(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            link = dict(attrs).get("href", "")
            if link.startswith("https://global.synologydownload.com/") and link.endswith(".pat"):
                self.links.append(link)


def fetch(url):
    result = subprocess.run(
        ["curl", "--fail", "--silent", "--show-error", "--location", "--max-time", "30", url],
        check=True, capture_output=True, text=True,
    )
    return result.stdout


def version_key(release):
    version, revision = release.rsplit("-", 1)
    if version.count(".") == 1:
        version += ".0"
    return f"{version}-{revision}-0"


def collect(release, models):
    parser = PatLinks()
    parser.feed(fetch(f"{ARCHIVE}/{release}"))
    revision = release.rsplit("-", 1)[1]
    matches = []
    for url in parser.links:
        filename = urllib.parse.unquote(url.rsplit("/", 1)[1])
        match = re.fullmatch(rf"DSM_(.+)_{revision}\.pat", filename)
        if match and match.group(1) in models:
            matches.append((match.group(1), version_key(release), url))
    return matches


def checksum(entry):
    model, version, url = entry
    body = fetch(url + ".md5").strip()
    match = re.fullmatch(r"([0-9a-fA-F]{32})(?:\s+\S+)?", body)
    if not match:
        raise ValueError(f"Invalid MD5 sidecar for {model} {version}: {url}.md5")
    return model, version, url, match.group(1).lower()


def main():
    args_parser = argparse.ArgumentParser(description=__doc__)
    args_parser.add_argument("models", nargs="+", help="Exact Synology model names")
    args_parser.add_argument("--file", type=Path, default=Path("config/pats.json"))
    args_parser.add_argument("--dry-run", action="store_true")
    args = args_parser.parse_args()

    original = json.loads(args.file.read_text())
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        batches = list(executor.map(lambda release: collect(release, set(args.models)), RELEASES))
        entries = [entry for batch in batches for entry in batch]
        results = list(executor.map(checksum, entries))

    additions = 0
    for model, version, url, md5 in results:
        value = {"sum": md5, "url": url}
        previous = original.setdefault(model, {}).get(version)
        if previous and previous != value:
            raise ValueError(f"Existing entry differs for {model} {version}: {previous} != {value}")
        if previous is None:
            original[model][version] = value
            additions += 1
            print(f"ADD {model} {version} {md5}")

    missing = sorted(set(args.models) - {model for model, _, _, _ in results})
    if missing:
        print("No PAT found in the checked releases for: " + ", ".join(missing))
    print(f"Verified {len(results)} official MD5 sidecars; {additions} new entries")
    if not args.dry_run and additions:
        args.file.write_text(json.dumps(original, indent=2) + "\n")


if __name__ == "__main__":
    main()
