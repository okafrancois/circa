#!/usr/bin/env python3
"""Generate the built-in content blocker's declarativeNetRequest rulesets from EasyList.

The pinned source lives in release/content-blocking.json: the easylist/easylist repository, its
`gh-pages` commit and the SHA-256 of each downloaded list. Generated rulesets are separate data
under native/ThirdParty/easylist/ (GPLv3 or CC BY-SA 3.0, see its LICENSE.md); the list texts
themselves are never committed.

Usage (run with `python3 -I`):
  scripts/content-blocking-rules.py check              # offline: rulesets match the pin and limits
  scripts/content-blocking-rules.py generate           # regenerate from the pinned commit
  scripts/content-blocking-rules.py update [--commit SHA]  # pin the latest (or given) commit
  scripts/content-blocking-rules.py rollback           # restore the previous pin and regenerate
  scripts/content-blocking-rules.py generate --lists DIR   # convert local easylist.txt/easyprivacy.txt

Only network filters are converted. Cosmetic filters, regular expressions and options that
declarativeNetRequest cannot express (popup, csp, redirect, rewrite, removeparam, ...) are
skipped, never approximated, so a skipped filter can only under-block. Whole-document blocking
(`$document` without `@@`) is skipped too: it would replace pages with an engine error page.
"""
import argparse
import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PIN = REPO / "release/content-blocking.json"
OUTPUT = REPO / "native/ThirdParty/easylist"
EXTENSION_MANIFEST = REPO / "native/OrbitChromium/ContentBlocker/manifest.json"
RAW = "https://raw.githubusercontent.com/{repository}/{commit}/{path}"
LATEST = "https://api.github.com/repos/{repository}/commits/{branch}"
LISTS = ("easylist", "easyprivacy")

# declarativeNetRequest limits (Chromium extensions/common/api/declarative_net_request/constants).
# The guaranteed per-extension static budget; rules beyond it depend on a shared global pool.
MAX_ENABLED_STATIC_RULES = 30_000
MAX_REGEX_RULES = 1_000

BLOCK_PRIORITY = 1
ALLOW_PRIORITY = 2
IMPORTANT_PRIORITY = 3

TYPES = {
    "script": "script", "image": "image", "stylesheet": "stylesheet", "object": "object",
    "xmlhttprequest": "xmlhttprequest", "subdocument": "sub_frame", "ping": "ping",
    "media": "media", "font": "font", "websocket": "websocket", "other": "other",
    "object-subrequest": "object", "beacon": "ping", "xhr": "xmlhttprequest", "css": "stylesheet",
    "frame": "sub_frame",
}
ALL_TYPES = ["sub_frame", "stylesheet", "script", "image", "font", "object", "xmlhttprequest",
             "ping", "csp_report", "media", "websocket", "webtransport", "webbundle", "other"]
METHODS = {"connect", "delete", "get", "head", "options", "patch", "post", "put"}
COSMETIC_ONLY = {"elemhide", "generichide", "genericblock", "ehide", "ghide", "specifichide", "shide"}
HOST = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")
PURE_HOST = re.compile(r"^\|\|([^/*^|$]+)\^\|?$")
COSMETIC = re.compile(r"#[@?$%]?#|#\+js\(")


class Skip(Exception):
    pass


def a_label(domain):
    domain = domain.strip().lower().rstrip(".")
    if not domain.isascii():
        try:
            domain = domain.encode("idna").decode("ascii")
        except UnicodeError as error:
            raise Skip("domain") from error
    if not HOST.match(domain):
        raise Skip("domain")
    return domain


def split_options(body):
    """The last `$` starts options unless it belongs to the pattern (a `$` followed by `/`)."""
    index = body.rfind("$")
    if index < 0 or "/" in body[index:] and "=" not in body[index:]:
        return body, []
    return body[:index], [option for option in body[index + 1:].split(",") if option]


def parse_filter(line):
    """One ABP network filter to (key, rule-without-id) or raises Skip(reason)."""
    exception = line.startswith("@@")
    body = line[2:] if exception else line
    if body.startswith("/") and len(body) > 1 and (body.endswith("/") or re.search(r"/\$[^/]+$", body)):
        raise Skip("regex")
    pattern, options = split_options(body)
    types, excluded, initiators, excluded_initiators, methods = set(), set(), [], [], set()
    domain_type = None
    case_sensitive = important = document = False
    for raw in options:
        name, _, value = raw.partition("=")
        negated = name.startswith("~")
        name = name.lstrip("~").lower()
        if name in TYPES:
            (excluded if negated else types).add(TYPES[name])
        elif name in ("third-party", "3p"):
            domain_type = "firstParty" if negated else "thirdParty"
        elif name in ("first-party", "1p"):
            domain_type = "thirdParty" if negated else "firstParty"
        elif name in ("domain", "from"):
            for entry in value.split("|"):
                if "*" in entry or not entry.strip("~"):
                    raise Skip("domain-wildcard")
                (excluded_initiators if entry.startswith("~") else initiators).append(a_label(entry.lstrip("~")))
        elif name == "match-case":
            case_sensitive = True
        elif name == "important" and not exception:
            important = True
        elif name == "document" and not negated:
            document = True
        elif name == "method":
            for entry in value.lower().split("|"):
                if entry.startswith("~") or entry not in METHODS:
                    raise Skip("method")
                methods.add(entry)
        elif name in COSMETIC_ONLY and exception:
            raise Skip("cosmetic-exception")
        else:
            raise Skip("option:" + name)
    if document and not exception:
        raise Skip("document-block")
    if types and excluded:
        types -= excluded
        excluded = set()
        if not types:
            raise Skip("empty-types")
    condition = {}
    if document:
        action = "allowAllRequests"
        types, excluded = {"main_frame", "sub_frame"}, set()
    else:
        action = "allow" if exception else "block"
    if types:
        condition["resourceTypes"] = sorted(types)
    elif excluded:
        # An explicit exclusion list would otherwise include main_frame.
        condition["excludedResourceTypes"] = sorted(excluded | {"main_frame"})
    if domain_type:
        condition["domainType"] = domain_type
    if initiators:
        condition["initiatorDomains"] = sorted(set(initiators))
    if excluded_initiators:
        condition["excludedInitiatorDomains"] = sorted(set(excluded_initiators))
    if methods:
        condition["requestMethods"] = sorted(methods)
    priority = IMPORTANT_PRIORITY if important else ALLOW_PRIORITY if exception else BLOCK_PRIORITY

    host = PURE_HOST.match(pattern)
    if host and not initiators and not excluded_initiators and not case_sensitive:
        # `||host^` is exactly requestDomains: the host and its subdomains. Grouped below.
        key = (action, priority, json.dumps(condition, sort_keys=True))
        return key, a_label(host.group(1))
    if pattern in ("", "*"):
        if not initiators and not methods:
            raise Skip("too-broad")
    else:
        if not pattern.isascii():
            raise Skip("non-ascii")
        if pattern.startswith("||*"):
            pattern = pattern[2:]
        while pattern.startswith("**"):
            pattern = pattern[1:]
        if pattern in ("", "*", "|", "||"):
            raise Skip("too-broad")
        condition["urlFilter"] = pattern
        if case_sensitive:
            condition["isUrlFilterCaseSensitive"] = True
    return None, {"priority": priority, "action": {"type": action}, "condition": condition}


def convert(text):
    groups, singles, skipped, seen = {}, [], {}, set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("!") or line.startswith("[") or COSMETIC.search(line):
            continue
        try:
            key, value = parse_filter(line)
        except Skip as reason:
            skipped[str(reason)] = skipped.get(str(reason), 0) + 1
            continue
        if key is not None:
            groups.setdefault(key, set()).add(value)
            continue
        encoded = json.dumps(value, sort_keys=True)
        if encoded not in seen:
            seen.add(encoded)
            singles.append(value)
    rules = []
    for (action, priority, condition), domains in sorted(groups.items()):
        merged = json.loads(condition)
        merged["requestDomains"] = sorted(domains)
        rules.append({"priority": priority, "action": {"type": action}, "condition": merged})
    rules.extend(singles)
    for index, rule in enumerate(rules, start=1):
        rule["id"] = index
    return rules, skipped


def validate(rules):
    ids = set()
    for rule in rules:
        if not isinstance(rule.get("id"), int) or rule["id"] < 1 or rule["id"] in ids:
            raise SystemExit("invalid or duplicate rule id: %r" % rule.get("id"))
        ids.add(rule["id"])
        action, condition = rule["action"]["type"], rule["condition"]
        if action not in ("block", "allow", "allowAllRequests"):
            raise SystemExit("unexpected action in rule %d" % rule["id"])
        if action == "allowAllRequests" and set(condition.get("resourceTypes", [])) - {"main_frame", "sub_frame"}:
            raise SystemExit("allowAllRequests outside frames in rule %d" % rule["id"])
        if "resourceTypes" in condition and "excludedResourceTypes" in condition:
            raise SystemExit("both resource type lists in rule %d" % rule["id"])
        url = condition.get("urlFilter")
        if url is not None and (not url or not url.isascii() or url.startswith("||*")):
            raise SystemExit("invalid urlFilter in rule %d" % rule["id"])
        for key in ("requestDomains", "initiatorDomains", "excludedInitiatorDomains"):
            for domain in condition.get(key, []):
                if not HOST.match(domain):
                    raise SystemExit("invalid domain %r in rule %d" % (domain, rule["id"]))
        if "regexFilter" in condition:
            raise SystemExit("regex rules are not generated")
    return len(rules)


def encode(rules):
    """One rule per line keeps refresh diffs reviewable."""
    return "[\n" + ",\n".join(json.dumps(rule, sort_keys=True, separators=(",", ":")) for rule in rules) + "\n]\n"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "content-blocking-rules"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def load_pin():
    return json.loads(PIN.read_text())


def save_pin(pin):
    PIN.write_text(json.dumps(pin, indent=2, sort_keys=True) + "\n")


def list_texts(pin, lists_dir=None):
    texts = {}
    source = pin["source"]
    for name in LISTS:
        entry = source["lists"][name]
        if lists_dir:
            data = (Path(lists_dir) / entry["path"]).read_bytes()
        else:
            data = fetch(RAW.format(repository=source["repository"], commit=source["commit"], path=entry["path"]))
        if entry.get("sha256") and sha256(data) != entry["sha256"]:
            raise SystemExit("%s differs from the pinned SHA-256; refusing to generate" % name)
        entry["sha256"] = sha256(data)
        texts[name] = data.decode("utf-8")
    return texts


def list_version(text):
    found = re.search(r"^! Version: (\d{12})$", text, re.MULTILINE)
    return found.group(1) if found else "0"


def generate(pin, lists_dir=None, output=OUTPUT, manifest=EXTENSION_MANIFEST):
    texts = list_texts(pin, lists_dir)
    total, report = 0, {}
    output.mkdir(parents=True, exist_ok=True)
    for name in LISTS:
        rules, skipped = convert(texts[name])
        count = validate(rules)
        total += count
        data = encode(rules).encode()
        (output / (name + ".json")).write_bytes(data)
        report[name] = {"rules": count, "sha256": sha256(data), "version": list_version(texts[name]),
                        "skipped": dict(sorted(skipped.items()))}
    if total > MAX_ENABLED_STATIC_RULES:
        raise SystemExit("%d static rules exceed the guaranteed %d" % (total, MAX_ENABLED_STATIC_RULES))
    pin["generated"] = {name: {key: report[name][key] for key in ("rules", "sha256", "version")} for name in LISTS}
    if manifest and manifest.exists():
        document = json.loads(manifest.read_text())
        # Chrome versions are at most four dot-separated integers below 65536.
        stamp = max(report[name]["version"] for name in LISTS)
        document["version"] = "1.%s.%s.%s" % (stamp[2:6], stamp[6:10], stamp[10:12])
        manifest.write_text(json.dumps(document, indent=2) + "\n")
    return report


def check(pin=None, output=OUTPUT):
    pin = pin or load_pin()
    total = 0
    for name in LISTS:
        expected = pin["generated"][name]
        data = (output / (name + ".json")).read_bytes()
        if sha256(data) != expected["sha256"]:
            raise SystemExit("%s.json differs from release/content-blocking.json; run generate" % name)
        total += validate(json.loads(data))
    if total > MAX_ENABLED_STATIC_RULES:
        raise SystemExit("%d static rules exceed the guaranteed %d" % (total, MAX_ENABLED_STATIC_RULES))
    return total


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("check", "generate", "update", "rollback"))
    parser.add_argument("--lists", help="directory with local easylist.txt and easyprivacy.txt")
    parser.add_argument("--commit", help="update: pin this commit instead of the branch head")
    args = parser.parse_args(argv)
    if args.command == "check":
        print(json.dumps({"rules": check()}))
        return 0
    pin = load_pin()
    if args.command == "update":
        source = pin["source"]
        commit = args.commit or json.loads(fetch(LATEST.format(**source)))["sha"]
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise SystemExit("invalid commit")
        if commit == source["commit"]:
            print(json.dumps({"commit": commit, "unchanged": True}))
            return 0
        pin["previous"] = {"source": json.loads(json.dumps(source)), "generated": pin.get("generated")}
        source["commit"] = commit
        for name in LISTS:
            source["lists"][name]["sha256"] = ""
    elif args.command == "rollback":
        previous = pin.get("previous")
        if not previous:
            raise SystemExit("no previous pin to restore")
        pin = {"source": previous["source"], "generated": previous.get("generated"),
               "previous": {"source": pin["source"], "generated": pin.get("generated")}}
    report = generate(pin, args.lists)
    save_pin(pin)
    print(json.dumps({"commit": pin["source"]["commit"], "lists": report}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
