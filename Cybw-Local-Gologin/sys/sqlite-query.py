#!/usr/bin/env python
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as conn:
    conn.execute(sys.argv[2])
    conn.commit()