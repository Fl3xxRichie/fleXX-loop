# Local-first dev infra: Docker Postgres + Drizzle + storage driver + health

Known-good shapes for tasks that stand up a LOCAL development stack (dev database in Docker, migrations, media-storage abstraction, health endpoint) instead of cloud services. Verified on Windows + Next.js App Router + Drizzle 0.31 (postgres-js), with drizzle-kit + tsx.

## Docker Postgres
- `docker-compose.yml` at repo root: `postgres:16-alpine`, named volume, dev-only creds, `5432:5432`, a `pg_isready` healthcheck.
- `db:up` = `docker compose up -d --wait` (blocks until healthy, so `db:up && db:migrate` works on first run); `db:down` = `docker compose down`. The named volume survives down/up (verify a table still exists after the cycle); only `down -v` wipes data.
- Compose prefixes volume/network names with the project directory it runs from (e.g. `store_flexxship-pgdata` when the compose file sits in `store/`) - expected, not a bug.
- Inspect it from the host with `docker exec <container> psql -U postgres -d <db> -c '<sql>'` (`-t -c` for bare values); `pg_stat_activity` shows who is connected and what each connection last ran.

## Drizzle with zero tables yet
- `drizzle-kit migrate` needs `drizzle/meta/_journal.json` COMMITTED: without it, migrate exits 1 after the spinner with NO error message. Create the baseline with one `npx drizzle-kit generate` on the empty schema ("No schema changes, nothing to migrate" - but `drizzle/meta/_journal.json` appears), commit it, and migrate then runs and creates `drizzle.__drizzle_migrations`.
- Generate a table's migration only in the task that owns the table; other tasks extend `src/db/schema.ts` and let their generated migrations append to the same journal. Never hand-create journal entries.
- `drizzle.config.ts` runs outside Next.js: load env with `loadEnvConfig(process.cwd())` from `@next/env`, plus a local-DSN fallback so `db:migrate` works before any `.env.local` exists.
- Keep a placeholder `src/db/schema.ts` (may export nothing) so the configured schema path resolves.

## Build-safe DB client + health route
- Lazy client factories (`getSql()`/`getDb()`) so importing the module never requires `DATABASE_URL`: `next build` and route collection stay green with no env at all.
- Health route: `export const dynamic = "force-dynamic"` + `SELECT 1` in try/catch, returning `{ok:true, db:true}`, else 503 `{ok:false, db:false}`. Verify live against the local DB AND inside an env-less copy.

## Script lifecycle: end the Postgres client or the process hangs
- postgres.js (drizzle-orm/postgres-js) keeps the Node event loop alive while its pool holds open sockets: a tsx script that finished every step prints its summary and then hangs forever at ~0% CPU, because nothing calls `sql.end()`. A run that printed everything and then hangs is a missing-close signature, not slow I/O.
- Debugging signature: long uptime with frozen CPU, and `pg_stat_activity` shows an `idle` connection with `wait_event_type = 'Client'` whose last query is the script's final statement.
- Fix: keep the lazy `getSql()/getDb()` factories and add `closeDb()` beside them - capture the client, clear the module state, `await client.end({ timeout: 5 })`. Every CLI script wraps its body in an async `run()` whose `finally` awaits `closeDb()` and sets `process.exitCode = 1` on failure (never `process.exit()`, which skips the finally). The Next server never calls it; its pool lives for the process lifetime.
- Acceptance check for script tasks: confirm the process EXITS, not just that it printed; then confirm no hung copy survives before re-running (see `references/unattended-run-mechanics.md`).
- Already-hung process and no one to approve a force-kill: terminate its backend from the server instead - `select pg_terminate_backend(pid) from pg_stat_activity where datname = '<db>' and state = 'idle' and coalesce(query,'') ~ '(tables_the_script_touched)'` - releasing the last handle lets the node process exit gracefully within seconds.

## Connection saturation and restarting the dev DB
- Every Next dev-server hot reload re-evaluates the lazy db module, and each re-evaluated version can create its OWN postgres.js pool (up to ~5 sockets each). After a long edit session the dev server alone can hold most of `max_connections`; then unrelated clients - `docker exec ... psql`, a build worker, even the superuser reserved slots - fail with `sorry, too many clients already`. Recognise it by the message arriving from something that is NOT the app under test. Durable hardening: keep the single client on `globalThis` so hot reloads reuse one pool (`closeDb()` still clears and ends it for scripts) and set `idle_timeout` (~20s) so idle sockets self-release - the leak class then disappears.
- First remedy while a slot is still free: terminate idle backends - `docker exec <container> psql -U postgres -d <db> -c "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname='<db>' and pid <> pg_backend_pid() and state='idle'"`. postgres.js reconnects transparently, so the running app keeps working.
- Fully saturated (even psql cannot connect): restart the server. `docker restart/stop/kill` is gated unattended, and NEVER `pg_ctl restart` inside the container: the official image runs postgres as PID 1, so the shutdown kills the container itself (the exec dies with 137; `docker ps -a` shows `Exited (0)`) and compose has no restart policy. Bring it back with `npm run db:up` (`docker compose up -d --wait`), which re-runs the healthcheck before returning.
- Before a DB-backed build (generateStaticParams and friends) on a shared dev DB, check headroom: `show max_connections` vs the current count - each Next build worker holds its own pool (up to ~5), and workers multiply.

## Storage driver abstraction (local now, hosted later)
- Interface `uploadFile(key, buffer)` + `publicUrl(key)`. Local driver writes `<repo>/public/uploads/<key>` and returns `/uploads/<key>` URLs; gitignore the folder contents but keep the folder with `!/public/uploads/.gitkeep`.
- The hosted driver lives in its own module, imported via `await import(...)` inside the hosted branch only: local dev never loads its SDK and never needs credentials; its env vars stay optional and unset.
- Verify with a script (`tsx scripts/storage-check.ts`) that loads env like Next does, uploads a test object, and prints the resolved URL; then curl that URL against the running app to prove serving.

## Packages that worked
deps: `drizzle-orm`, `postgres`, `@next/env` (plus `@aws-sdk/client-s3` for the hosted module only, and `sharp` when the task converts images such as WebP mirrors); dev: `drizzle-kit`, `tsx` (wrap script bodies in an async `run()` with try/catch/finally - the finally closes the DB client, see script lifecycle above; module mode never matters that way).

## End-to-end check sequence
`db:up` -> `docker ps` healthy -> `db:migrate` exit 0 -> `psql \dt drizzle.*` -> health endpoint `{ok:true,db:true}` -> `storage:check` -> curl the printed URL (200) -> `db:down`/`db:up` -> health still true and data persisted -> full CI gate in a pristine env-less copy: robocopy the tree to a FRESH uniquely-named scratch dir (exclude `node_modules`, `.next`, `.git`, `.env.local` and any large upload dir; robocopy exit codes up to 7 are success), `npm ci`, then the repo's full gate. A new dir name each time beats cleaning an old copy. Pass any env the gate needs (e.g. a DB URL) inline in the command - background shells do not inherit session exports; DB-backed builds also need connection headroom (see the saturation section above).
