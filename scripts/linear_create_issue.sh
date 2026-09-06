#!/usr/bin/env bash
# Create a Linear issue via the GraphQL API.
# Usage: linear_create_issue.sh "<title>" "<markdown body>"
# Env:   LINEAR_API_KEY   (required)
#        LINEAR_TEAM_KEY  (optional; defaults to the first team visible to the key)
set -euo pipefail

title="${1:?usage: linear_create_issue.sh <title> <body>}"
body="${2:-}"
: "${LINEAR_API_KEY:?LINEAR_API_KEY is not set}"

api='https://api.linear.app/graphql'

gql() {
  curl -fsS --max-time 30 "$api" \
    -H "Authorization: $LINEAR_API_KEY" \
    -H 'Content-Type: application/json' \
    --data-binary @-
}

team_id="$(
  python3 -c 'import json,sys; print(json.dumps({"query":"{ teams { nodes { id key name } } }"}))' \
  | gql \
  | python3 -c 'import json,os,sys
d=json.load(sys.stdin)
nodes=d.get("data",{}).get("teams",{}).get("nodes",[])
if not nodes:
    sys.exit("no Linear teams visible to this API key: " + json.dumps(d.get("errors")))
want=os.environ.get("LINEAR_TEAM_KEY","").strip()
if want:
    hit=[n for n in nodes if n["key"]==want]
    if not hit:
        keys=[n["key"] for n in nodes]
        sys.exit(f"team key {want!r} not found; available: {keys}")
    print(hit[0]["id"])
else:
    print(nodes[0]["id"])'
)"

TITLE="$title" BODY="$body" TEAM_ID="$team_id" python3 -c 'import json,os
q="mutation($input: IssueCreateInput!){ issueCreate(input:$input){ success issue { identifier url } } }"
v={"input":{"teamId":os.environ["TEAM_ID"],"title":os.environ["TITLE"],"description":os.environ["BODY"]}}
print(json.dumps({"query":q,"variables":v}))' \
| gql \
| python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("data",{}).get("issueCreate") or {}
if not r.get("success"):
    sys.exit("issueCreate failed: " + json.dumps(d.get("errors") or d))
id_=r["issue"]["identifier"]
u=r["issue"]["url"]
print(f"created {id_} {u}")'
