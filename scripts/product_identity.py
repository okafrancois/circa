"""Read the single product identity definition used by Swift and packaging."""
from pathlib import Path
import re

SOURCE = Path(__file__).resolve().parents[1] / 'native/Sources/BrowserCore/ProductIdentity.swift'
IDENTITY = dict(re.findall(r'public static let (\w+) = "([^"\n]+)"', SOURCE.read_text()))
BUNDLE_ID = IDENTITY['bundleIdentifier']
PRODUCT_NAME = IDENTITY['displayName']
