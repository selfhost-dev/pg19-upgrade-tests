# Field notes (test log, 2026-11-24)

Real mistakes from this test run, in the order they happened. Raw material for the
"what I got wrong the first time" section.

1. **I started tests while the 20 GB load still held port 5432.**
   Expected: the dump/restore and logical trials run beside the load.
   Happened: both failed at `pg_ctl start` because the port was taken.
   Cost: one wasted trial; now every script uses its own port or waits for the load.

2. **`kill -INT` did not stop pgbench.**
   Expected: SIGINT stops the background writers at cutover.
   Happened: a non-interactive bash starts background jobs with SIGINT ignored, so pgbench
   kept writing and the cutover loop waited for 10 minutes.
   Cost: 10 minutes and one invalid cutover number. Fix: `kill -TERM`.

3. **My sequence copy wrote `setval(..., t)`.**
   Expected: `format('%s', boolean)` prints `true`.
   Happened: it prints `t`, so every `setval` failed; psql without `ON_ERROR_STOP`
   hid the error, and the first insert on 19 hit `duplicate key value violates unique
   constraint "orders_pkey"`.
   Cost: one failed cutover. Fix: print `'true'`/`'false'` and run with `ON_ERROR_STOP=1`.
   Lesson for readers: the sequence step is the one people get wrong; check it.

4. **I measured `max_locks_per_transaction` with CREATE TABLE in one transaction.**
   Expected: create 12,000 tables, then lock them.
   Happened: the CREATE itself ran out of lock space (18 at table 7,460, 19 at 4,349).
   Cost: a second run. Fix: create in batches, then lock N tables in one transaction.

5. **I expected REPACK to move old pglz values to lz4.** It did not; neither did
   VACUUM FULL. Only rewriting the value (an UPDATE) did.

6. **The container had no init process.** Every exited `postgres`/`pgbench` stayed as a
   zombie until I restarted it with `docker run --init`.

7. **I built the image with `--no-install-recommends`, so it had no JIT.**
   Expected: `postgresql-19` includes JIT.
   Happened: PGDG ships LLVM JIT in `postgresql-NN-jit`, which is only a Recommends.
   Without it, `jit = on` does nothing and EXPLAIN shows no JIT section. My first JIT
   test (on vs off: 330 ms both) and my first FK benchmark ran without JIT on 18 and 19.
   Cost: two reruns. Lesson for readers: before you compare JIT on 18 and 19, run
   `select pg_jit_available();`.

8. **My first logical cutover on 21.3 GB took 21.7 s.** I cut over 30 s after the
   initial copy ended; the subscriber was still applying the writes that built up during
   the 13-minute copy. After waiting for lag < 16 MB (90 s more), the cutover took 0.32 s.
