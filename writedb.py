#!/usr/bin/env python3
import sys
import sqlite3
import json

data = json.loads(open(sys.argv[1]).read())
con = sqlite3.connect(sys.argv[2])

cur = con.cursor()

for server, channels in data.items():
    for ch in channels:
        cur.execute("insert into channels values (?, ?, ?, ?, ?)",
                    (
                        ch["channel_id"],
                        ch["server_id"],
                        ch["latest_post"],
                        ch["post_count"],
                        json.dumps(ch["tags"])
                    ))

con.commit()
con.close()
