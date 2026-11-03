"""Two real PostgreSQL sessions contend for the final quota and for one slot.
Run on a freshly seeded disposable database. Requires psql in PATH or PSQL env.
Connection settings: standard PGHOST/PGPORT/PGUSER/PGDATABASE variables.
"""
import os
import subprocess
import time

PSQL = os.environ.get('PSQL', 'psql')

def run(sql, check=True):
    r = subprocess.run([PSQL, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', sql],
                       capture_output=True, text=True, encoding='utf-8')
    if check and r.returncode:
        raise RuntimeError(r.stderr)
    return r

def race(slot2):
    # Roll back all setup only by dropping the disposable test database afterwards.
    sql = "SET search_path=clinic,public; BEGIN; SELECT book_appointment(5,4,'self',9); SELECT pg_sleep(1); COMMIT;"
    first = subprocess.Popen([PSQL, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', sql],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8')
    time.sleep(0.2)
    second = run(f"SET search_path=clinic,public; SELECT book_appointment(6,{slot2},'self',10);", False)
    out, err = first.communicate(timeout=20)
    assert first.returncode == 0, err
    assert second.returncode != 0, 'Both competing bookings succeeded'
    assert 'quota' in second.stderr.lower() or 'unique' in second.stderr.lower(), second.stderr
    assert run("SELECT count(*) FROM clinic.appointments WHERE slot_id=4 AND status<>'cancelled'").stdout.strip() == '1'
    run("SET search_path=clinic,public; UPDATE appointments SET status='cancelled' WHERE patient_id=5 AND status='planned';")

# Cancel the seeded planned self booking; exactly one self quota remains.
run("SET search_path=clinic,public; CALL cancel_appointment(3);")
race(5)  # distinct slots, one remaining quota
race(4)  # same slot
print('Concurrency passed: one winner for final quota and for occupied slot')
