#!/usr/bin/env python3
"""
wayback_domain_dump.py

Backward-compatible wrapper. All logic now lives in the wayback_cdx package.

Usage (interactive, original behavior):
    python wayback_domain_dump.py

Usage (CLI flags):
    python wayback_domain_dump.py --domain example.com --output out.txt --resume

Usage (as module):
    python -m wayback_cdx --domain example.com
"""
from wayback_cdx.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
