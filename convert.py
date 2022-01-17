#!/usr/bin/env python3
import csv
import json
import os
import sys
import requests
from dotenv import load_dotenv

load_dotenv()

f = open(sys.argv[1])

reader = csv.reader(f)
reader.__next__()

entries = {}

for server, chid, channel, _, _ in reader:
    server = int(server)
    if chid.isnumeric():
        if not server in entries:
            entries[server] = []

        src = json.loads(channel)
        res = {
            "channel_id":  int(chid),
            "server_id":   server,
            "latest_post": int(src["latest"]["N"]),
            "post_count":  0,
            "tags":        src["tags"]["L"]
        }

        for i in range(len(res["tags"])):
            res["tags"][i] = res["tags"][i]["S"]

        data = {
            "login": os.environ["DANBOORU_USERNAME"],
            "api_key": os.environ["DANBOORU_API_KEY"],
            "tags": " ".join([f"id:<={res['latest_post']}"] + res["tags"])
        }

        r = requests.get("https://danbooru.donmai.us/counts/posts.json", params = data)

        res["post_count"] = r.json()["counts"]["posts"]

        entries[server].append(res)

print(json.dumps(entries, indent=2))
f.close()
