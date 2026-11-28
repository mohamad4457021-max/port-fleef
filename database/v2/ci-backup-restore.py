"""CI ONLY: real PostgreSQL logical backup and isolated restore drill.
Never point this script at an operational database. Uses synthetic fixtures only.
"""
import json
import os
import pathlib
import subprocess
import tempfile
import time

SOURCE = os.environ.get("PGDATABASE")
TARGET = "portfleet_restore_test"
OWNER = "00000000-0000-4000-8000-000000000005"
STAFF = "00000000-0000-4000-8000-000000000002"
OP = "70000000-0000-4000-8000-000000000001"
INV = "70000000-0000-4000-8000-000000000002"

if SOURCE != "portfleet_test" or os.environ.get("GITHUB_ACTIONS") != "true":
    raise SystemExit("CI fixture database only")

def run(args, db=SOURCE):
    env = dict(os.environ, PGDATABASE=db)
    result = subprocess.run(args, env=env, text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr[:1500]}")
    return result.stdout.strip()

def sql(statement, db=SOURCE):
    return run(["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-c", statement], db)

def check(condition, msg):
    if not condition:
        raise AssertionError(msg)

# Concurrency tests have already advanced the first source revision.
# Use a second, fresh synthetic workspace to demonstrate continued operations.
sql(f"""
insert into public.portfleet_owner values ('{OWNER}');
insert into public.portfleet_state
select '{OWNER}'::uuid,1,snapshot from public.portfleet_state
where owner_id='00000000-0000-4000-8000-000000000001';
select portfleet_v2.stage_owner('{OWNER}',1);
insert into portfleet_v2.api_workspace values ('{OWNER}',true);
set role authenticated;
select set_config('request.jwt.claim.sub','{OWNER}',false);
select portfleet_v2_api.set_access('{OWNER}','{STAFF}','fuel.post',true);
select portfleet_v2_api.set_access('{OWNER}','{STAFF}','inventory.post',true);
select set_config('request.jwt.claim.sub','{STAFF}',false);
select portfleet_v2_api.post_fuel('{OWNER}','{OP}',0,'صرف','a','2026-01-02',10,'RESTORE-CI');
select portfleet_v2_api.post_inventory('{OWNER}','{INV}',0,'صرف','pt','w-open',1,'RESTORE-CI');
""")

# Compare all logical rows, including raw original records, permissions and audit.
# Sort deterministically; only digests/counts leave the database, not record contents.
tables = sql("""select schemaname||'.'||tablename from pg_tables
where schemaname in ('public','auth','portfleet_v2') order by 1""").splitlines()
check(len(tables) >= 19, "unexpected fixture schema")
def manifest(db):
    result = {}
    for table in tables:
        schema, name = table.split(".")
        check(schema in ("public", "auth", "portfleet_v2") and name.replace("_","").isalnum(), "invalid fixture table")
        result[table] = sql(f"""
        select jsonb_build_object('count',count(*),
        'digest',encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),'[]'::jsonb)::text,'UTF8')),'hex'))
        from "{schema}"."{name}" t
        """, db)
    result["audit_sequence"] = sql("select last_value||':'||is_called from portfleet_v2.server_audit_event_id_seq", db)
    return result

before = manifest(SOURCE)
with tempfile.TemporaryDirectory(prefix="portfleet-ci-") as temp:
    archive = pathlib.Path(temp) / "fixture.dump"
    started = time.monotonic()
    # Use the server image's matching PostgreSQL 16 utilities. Newer clients
    # can emit SET statements unsupported by PostgreSQL 16 during restore.
    container = os.environ["PG16_CONTAINER"]
    with archive.open("wb") as output:
        subprocess.run(["docker", "exec", container, "pg_dump", "-U", "postgres",
                        "-d", SOURCE, "--format=custom"], stdout=output,
                       stderr=subprocess.PIPE, check=True, timeout=120)
    dump_seconds = time.monotonic() - started
    check(archive.stat().st_size > 0, "empty archive")
    run(["createdb", TARGET])
    try:
        started = time.monotonic()
        with archive.open("rb") as source:
            subprocess.run(["docker", "exec", "-i", container, "pg_restore", "-U", "postgres",
                            "--exit-on-error", "--single-transaction", "--dbname", TARGET],
                           stdin=source, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           check=True, timeout=120)
        restore_seconds = time.monotonic() - started
        check(manifest(TARGET) == before, "restored data/sequence mismatch")
        check(sql(f"select count(*) from portfleet_v2.verify_owner('{OWNER}') where exact_match", TARGET) == "12", "baseline mismatch")
        check(sql("""select count(*) from pg_tables where schemaname='portfleet_v2' and not rowsecurity""", TARGET) == "0", "RLS not restored")
        check(sql("""select has_schema_privilege('anon','portfleet_v2_api','USAGE') or has_schema_privilege('authenticated','portfleet_v2','USAGE')""", TARGET) == "f", "schema privileges changed")
        check(sql("""select has_function_privilege('anon','portfleet_v2_api.post_fuel(uuid,uuid,bigint,text,text,date,numeric,text)','EXECUTE')""", TARGET) == "f", "anonymous execute granted")
        # Verify a restored staff identity can retry its exact transaction without
        # duplicating it, and can record another authorized transaction.
        result = sql(f"""
        set role authenticated;
        select set_config('request.jwt.claim.sub','{STAFF}',false);
        select portfleet_v2_api.post_fuel('{OWNER}','{OP}',0,'صرف','a','2026-01-02',10,'RESTORE-CI');
        select portfleet_v2_api.post_inventory('{OWNER}','{INV}',0,'صرف','pt','w-open',1,'RESTORE-CI');
        select portfleet_v2_api.post_fuel('{OWNER}','70000000-0000-4000-8000-000000000003',1,'صرف','a','2026-01-02',1,'RESTORE-NEW');
        """, TARGET).splitlines()
        check(result[-3:] == ["1","1","2"], "restored operations failed")
        check(sql(f"select count(*) from portfleet_v2.server_audit where owner_id='{OWNER}'", TARGET) == "5", "restored audit duplication")
        check(manifest(SOURCE) == before, "restore modified source database")
        print(json.dumps({"status":"PASS","tables_verified":len(tables),"archive_bytes":archive.stat().st_size,
                          "dump_seconds":round(dump_seconds,3),"restore_seconds":round(restore_seconds,3),
                          "scope":"synthetic fixture, same PostgreSQL cluster; no production RPO/RTO claim"}))
    finally:
        run(["dropdb", TARGET])
