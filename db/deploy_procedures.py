#!/usr/bin/env python3
"""Redeploy stored procedures from db/procedures/ using project DB credentials."""
from __future__ import annotations

from db.uploader import deploy_procedures


def main() -> None:
    deploy_procedures()
    print("All procedures deployed.")


if __name__ == "__main__":
    main()
