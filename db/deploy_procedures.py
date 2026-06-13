#!/usr/bin/env python3
"""Redeploy stored procedures from db/procedures/ using project DB credentials."""
from __future__ import annotations

import argparse

from db.uploader import deploy_procedures


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Redeploy stored procedures from db/procedures/.",
    )
    parser.add_argument(
        "--kill-blockers",
        action="store_true",
        help=(
            "Terminate in-flight fly_profiling / fraud-rule queries that hold "
            "procedure metadata locks (use during release when parse workers "
            "may still be running)."
        ),
    )
    args = parser.parse_args()
    deploy_procedures(kill_blockers=args.kill_blockers)
    print("All procedures deployed.")


if __name__ == "__main__":
    main()
