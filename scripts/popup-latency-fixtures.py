#!/usr/bin/env python3
"""Generate unpacked MV3 latency fixtures in an explicitly supplied lab directory."""
import argparse
import json
from pathlib import Path


def generate(root):
    for kind in ("trivial", "heavy"):
        destination = root / kind
        destination.mkdir(parents=True, exist_ok=False)
        manifest = {"manifest_version": 3, "name": "Popup Latency " + kind.title(),
                    "version": "1.0", "action": {"default_popup": "popup.html"},
                    "commands": {"_execute_action": {"suggested_key": {"default": "Ctrl+Shift+Y"}}}}
        if kind == "heavy":
            manifest["background"] = {"service_worker": "worker.js"}
            (destination / "worker.js").write_text(
                "chrome.runtime.onMessage.addListener((message, sender, reply) => { reply({ready:true}); });\n")
        (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (destination / "popup.html").write_text(
            '<!doctype html><meta charset="utf-8"><style>body{width:320px;height:200px}</style>'
            '<p id="status">Loading fixture</p><script src="popup.js"></script>')
        script = "performance.mark('popup-script-start');\n"
        if kind == "heavy":
            # Parsed executable source rather than a large comment or an artificial delay.
            script += "const records=[\n" + ",\n".join(
                json.dumps({"index": i, "label": "Synthetic record %d" % i, "value": i * 7})
                for i in range(60000)) + "];\n"
            script += ("chrome.runtime.sendMessage({ready:true}, reply => {"
                       "performance.mark('popup-worker-reply');"
                       "document.querySelector('#status').textContent='Ready: '+records.length;});\n")
        else:
            script += "document.querySelector('#status').textContent='Ready';\n"
        script += "performance.mark('popup-script-end');\n"
        (destination / "popup.js").write_text(script)
    print(root)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    generate(arguments.output.resolve())
