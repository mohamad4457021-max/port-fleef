"""CI only: real concurrent PostgreSQL connections against synthetic fixture."""
import concurrent.futures
import subprocess
import threading

OWNER = "00000000-0000-4000-8000-000000000001"

def sql(statement):
    return subprocess.run(
        ["psql", "-X", "-At", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose", "-c", statement],
        text=True, capture_output=True, timeout=30, check=False,
    )

def ok(statement):
    r = sql(statement)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()

def fail(statement, message):
    r = sql(statement)
    assert r.returncode != 0 and message in r.stderr, (r.stdout, r.stderr)

def race(a, b, both=False):
    barrier = threading.Barrier(2)
    def execute(q):
        barrier.wait(timeout=10)
        return sql(q)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(execute, q) for q in (a, b)]
        results = [f.result() for f in futures]
    successes = [r for r in results if r.returncode == 0]
    failures = [r for r in results if r.returncode != 0]
    assert len(successes) == (2 if both else 1), [(r.stdout, r.stderr) for r in results]
    if not both:
        assert len(failures) == 1 and "40001" in failures[0].stderr, failures[0].stderr
    else:
        assert successes[0].stdout.strip() == successes[1].stdout.strip(), [r.stdout for r in successes]

def fuel(op, revision, qty):
    return f"select portfleet_v2.post_fuel('{OWNER}','{op}',{revision},'صرف','a','2026-01-02',{qty},'CI-RACE')"

def inventory(op, revision, qty):
    return f"select portfleet_v2.post_inventory('{OWNER}','{op}',{revision},'صرف','pt','w-open',{qty},'CI-RACE')"

assert ok(f"select portfleet_v2.stage_owner('{OWNER}',1)") == "1"
race(fuel("30000000-0000-4000-8000-000000000001",0,60),
     fuel("30000000-0000-4000-8000-000000000002",0,60))
assert ok(f"select count(*) from portfleet_v2.fuel_transaction where owner_id='{OWNER}'") == "1"
fail(fuel("30000000-0000-4000-8000-000000000003",1,60), "INSUFFICIENT_HISTORICAL_FUEL")
same = fuel("30000000-0000-4000-8000-000000000004",1,10)
race(same, same, both=True)
assert ok(f"select count(*) from portfleet_v2.fuel_transaction where owner_id='{OWNER}'") == "2"

race(inventory("40000000-0000-4000-8000-000000000001",0,6),
     inventory("40000000-0000-4000-8000-000000000002",0,6))
assert ok(f"select count(*) from portfleet_v2.inventory_transaction where owner_id='{OWNER}'") == "1"
fail(inventory("40000000-0000-4000-8000-000000000003",1,6), "INSUFFICIENT_PART_STOCK")
same = inventory("40000000-0000-4000-8000-000000000004",1,1)
race(same, same, both=True)
assert ok(f"select count(*) from portfleet_v2.inventory_transaction where owner_id='{OWNER}'") == "2"
assert ok(f"select balance_after from portfleet_v2.inventory_transaction where owner_id='{OWNER}' and sequence_no=2") in ("2", "2.000000")
assert ok(f"select count(*) from portfleet_v2.verify_owner('{OWNER}') where exact_match") == "12"
# Verify the prototype stops accepting writes when V1 has advanced.
# This database is disposable; this is the only deliberate source mutation.
ok(f"update public.portfleet_state set revision=revision+1 where owner_id='{OWNER}'")
fail(fuel("30000000-0000-4000-8000-000000000005",2,1), "STALE_OR_MISSING_STAGE")
fail(inventory("40000000-0000-4000-8000-000000000005",2,1), "STALE_OR_MISSING_STAGE")
print("PASS: concurrent fuel/stock requests, duplicate retries, overdraft, stale source and reconciliation")
