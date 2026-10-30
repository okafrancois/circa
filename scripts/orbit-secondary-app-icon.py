#!/usr/bin/env python3
"""Compatibility entry point for synchronizing the shipped application icon."""
import runpy
from pathlib import Path

if __name__ == '__main__':
    runpy.run_path(str(Path(__file__).with_name('orbit-app-icon.py')), run_name='__main__')
