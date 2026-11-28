"""CI ONLY: 100k synthetic fuel rows and 50 simultaneous read clients.
Benchmarks relational database queries, not HTTP, mobile UI or real user sessions.
Run after restore drill, on the disposable fixture DB only.
"""
import concurrent.futures
import json
import os
import subprocess
import threading
import time

if os.environ.get("PGDATABASE") != "portfleet_test" or os.environ.get("GITHUB_ACTIONS") != "true":
    raise SystemExit("CI fixture database only")
OWNER = "00000000-0000-4000-8000-000000000006"
CLIENTS = 50
ROWS = 100_000

def sql(statement):
    r = subprocess.run(
        ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-c", statement],
        text=True, capture_output=True, timeout=90,
    )
    if r.returncode:
        raise RuntimeError(r.stderr[:1500])
    return r.stdout.strip()

# Separate synthetic workspace; no production imports or writes through the public API.
# Direct row generation intentionally bypasses V1's snapshot size limit.
sql(f"""
insert into public.portfleet_owner values ('{OWNER}');
insert into portfleet_v2.workspace(owner_id,source_revision) values ('{OWNER}',1);
insert into portfleet_v2.fuel(owner_id,record_id,source_position,payload,asset_id,movement_date,kind,qty,meter)
select '{OWNER}'::uuid,'bench-'||i,i,
 jsonb_build_object('id','bench-'||i,'asset','','date',date '2024-01-01'+(i%1000),
 'kind','استلام','qty',1,'meter',0),
 null,date '2024-01-01'+(i%1000),'استلام',1,0
from generate_series(1,{ROWS}) i;
analyze portfleet_v2.fuel;
""")
assert sql(f"select count(*) from portfleet_v2.fuel where owner_id='{OWNER}'") == str(ROWS)
query = f"""select count(*)||':'||sum(qty) from portfleet_v2.fuel
where owner_id='{OWNER}' and movement_date >= date '2024-01-01'
and movement_date < date '2024-01-11'"""
assert sql(query) == "1000:1000"
plan = sql("explain (format json) "+query)
barrier = threading.Barrier(CLIENTS)
def read(_):
    barrier.wait(timeout=30)
    started = time.monotonic()
    result = sql(query)
    assert result == "1000:1000", result
    return (time.monotonic()-started)*1000
started = time.monotonic()
with concurrent.futures.ThreadPoolExecutor(max_workers=CLIENTS) as pool:
    samples = sorted(pool.map(read,range(CLIENTS)))
wall_ms = (time.monotonic()-started)*1000
print(json.dumps({"status":"PASS","synthetic_rows":ROWS,"concurrent_read_clients":CLIENTS,
 "correct_responses":len(samples),"p50_ms":round(samples[24],1),"p95_ms":round(samples[47],1),
 "max_ms":round(samples[-1],1),"wall_ms":round(wall_ms,1),
 "plan_uses_index":"Index" in plan,"scope":"local PostgreSQL read queries including psql process/connection overhead; not application latency"}))
