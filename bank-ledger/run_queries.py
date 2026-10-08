#!/usr/bin/env python3
"""Run every showcase query in sql/queries.sql and print the results.

    python run_queries.py          all queries
    python run_queries.py Q11      only the queries whose title starts with Q11
"""
import os
import sqlite3
import sys

import ledger
from app import print_table


def main():
    if not os.path.isfile(ledger.DB_PATH):
        print("No database yet - run  python app.py  once first.")
        sys.exit(1)
    wanted = sys.argv[1].upper() if len(sys.argv) > 1 else None
    conn = ledger.connect()
    buf, title = "", ""
    with open(os.path.join(ledger.BASE, "sql", "queries.sql"), encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("-- Q"):
                title = line[3:].strip()
            buf += line
            if sqlite3.complete_statement(buf):
                if not wanted or title.upper().startswith(wanted):
                    print(f"\n{title}")
                    try:
                        cur = conn.execute(buf)
                        print_table([d[0] for d in cur.description], cur.fetchall())
                    except sqlite3.Error as exc:
                        print(f"  [X] {exc}")
                buf = ""


if __name__ == "__main__":
    main()
