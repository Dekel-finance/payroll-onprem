/**
 * Bring a fresh install up to the point where somebody can sign in — and no
 * further. **It creates no payroll data.** A bureau's employees, clients and
 * payslips arrive through onboarding and the payroll-system sync; anything this
 * script invented would be a row the office has to find and delete before it
 * can trust what it is looking at.
 *
 * What it writes is only the four things an install cannot know about itself,
 * each of which some part of the platform fails closed without:
 *
 *   1. the agency        — `admin_agencies` + `console_office`. The tenant key
 *                          every other record is scoped by.
 *   2. the connector     — `console_michpal_workers`. `resolveWorker()` refuses
 *                          an agency with no row rather than falling back to a
 *                          shared worker (PAY-66) — correct in the cloud, where
 *                          the shared worker is ours; on-prem it means the
 *                          console answers "provision a connector" while the
 *                          connector runs two containers away.
 *   3. the first user    — `console_users`. The console signs a user in with a
 *                          password or an emailed one-time code, and on-prem
 *                          there is no mail sender configured and no row to send
 *                          a code to: the login page is correct, reachable and
 *                          unusable.
 *
 *                          It does NOT create an `admin_users` row. The admin
 *                          app is our backoffice — commercial fields, AI spend,
 *                          internal controls — and a bureau's own owner is not a
 *                          member of staff. Set `CREATE_ADMIN_USER=true` on an
 *                          install that is ours (cloud.dekel.io, the demo VM),
 *                          where the same person is both.
 *
 * Idempotent — every write is an upsert keyed on something stable, so running it
 * again after a version bump repairs a missing row without touching the rest.
 *
 *   docker compose cp register-install.mjs console:/app/register-install.mjs
 *   docker compose exec -T \
 *     -e AGENCY_NAME='לשכת …' \
 *     -e FIRST_USER_EMAIL=… -e FIRST_USER_PASSWORD=… \
 *     console node /app/register-install.mjs
 *
 * Copy it to /app rather than /tmp: Node resolves `mongodb` by walking up from
 * the script, and from /tmp it never reaches /app/node_modules.
 */
import { MongoClient, ObjectId } from "mongodb";
import { randomBytes, scryptSync } from "node:crypto";

const URI = process.env.MONGODB_URI ?? "mongodb://mongo:27017";
const DB = process.env.MONGODB_DB ?? "payroll";
// `||`, not `??`: every install's .env carries `MICHPAL_WORKER_URL=` as an
// EMPTY line, which is not nullish — `??` kept the empty string and seeded a
// connector row with no address, which every probe then reported as its own
// failure.
const BASE_URL = (process.env.MICHPAL_WORKER_URL || "http://michpal-worker:8080").replace(/\/+$/, "");
const TOKEN = process.env.WORKER_TOKEN || process.env.MICHPAL_WORKER_TOKEN || "";

// Empty means "not told", and not-told must not overwrite: the office renames
// itself from inside the console, and an automated re-run (the operator applies
// every release) that reset the name to the default would undo that rename on
// a schedule. The default participates only in $setOnInsert.
const AGENCY_NAME = (process.env.AGENCY_NAME ?? "").trim();
const FIRST_EMAIL = (process.env.FIRST_USER_EMAIL ?? "").trim().toLowerCase();
const FIRST_PASSWORD = process.env.FIRST_USER_PASSWORD ?? "";

/** Mirrors hashPassword() in apps/console-v2/lib/auth.ts and apps/admin/lib/auth.ts. */
function hashPassword(pw) {
  const salt = randomBytes(16);
  return `scrypt$${salt.toString("hex")}$${scryptSync(pw, salt, 64).toString("hex")}`;
}

const client = new MongoClient(URI);
await client.connect();
const db = client.db(DB);
const now = new Date().toISOString();

// ── 1. the agency ───────────────────────────────────────────────────────────
//
// An existing one always wins, so a re-run never forks the tenant. AGENCY_ID
// pins it for an install being rebuilt against a database that survived.
let agencyId = (process.env.AGENCY_ID ?? "").trim();
if (!agencyId) {
  const existing = await db.collection("admin_agencies").findOne({}, { projection: { _id: 1 } });
  agencyId = existing ? String(existing._id) : new ObjectId().toHexString();
}

await db.collection("admin_agencies").updateOne(
  { _id: agencyId },
  {
    // Only what was actually told. A bare repair run (the operator's) supplies
    // neither name nor email and therefore changes neither.
    $set: {
      status: "active",
      ...(AGENCY_NAME ? { name: AGENCY_NAME } : {}),
      ...(FIRST_EMAIL ? { ownerEmail: FIRST_EMAIL } : {}),
    },
    // The ingest bearer is generated once and never rotated by a re-run — a new
    // value here would silently break whatever is already pushing with the old.
    $setOnInsert: {
      apiKey: randomBytes(24).toString("hex"),
      provisionedAt: now,
      ...(AGENCY_NAME ? {} : { name: "הלשכה" }),
    },
  },
  { upsert: true },
);
// The console's own settings doc. `loadSettings` falls back to defaults when it
// is missing, so this exists to carry the NAME — the one thing a default cannot
// guess and the office sees on every screen.
await db.collection("console_office").updateOne(
  { _id: agencyId },
  {
    $set: { agencyId, updatedAt: now, ...(AGENCY_NAME ? { agencyName: AGENCY_NAME } : {}) },
    $setOnInsert: AGENCY_NAME ? {} : { agencyName: "הלשכה" },
  },
  { upsert: true },
);
console.log(`agency ${agencyId}${AGENCY_NAME ? `  "${AGENCY_NAME}"` : ""}`);

// ── 2. the Michpal connector ────────────────────────────────────────────────
if (!TOKEN) {
  console.log("WORKER_TOKEN unset — no connector row; the console will refuse every Michpal action");
} else {
  await db.collection("console_michpal_workers").updateOne(
    { agencyId, organizationId: { $exists: false } },
    {
      $set: { agencyId, name: "מיכפל — מקומי", baseUrl: BASE_URL, token: TOKEN, active: true },
      $setOnInsert: { createdAt: now },
    },
    { upsert: true },
  );
  console.log(`connector → ${BASE_URL}`);
}

// ── 3. the first user ───────────────────────────────────────────────────────
if (FIRST_EMAIL && FIRST_PASSWORD) {
  const passwordHash = hashPassword(FIRST_PASSWORD);
  await db.collection("console_users").updateOne(
    { email: FIRST_EMAIL },
    {
      $set: { email: FIRST_EMAIL, agencyId, role: "owner", status: "active", passwordHash, updatedAt: now },
      $setOnInsert: { createdAt: now },
    },
    { upsert: true },
  );
  // Staff access to the admin app, and only where we are the operator. On a
  // customer install the admin port is bound to loopback (docker-compose.yml)
  // and no admin user exists — two independent reasons the bureau cannot reach
  // a screen that was never meant for it.
  if (process.env.CREATE_ADMIN_USER === "true") {
    await db.collection("admin_users").updateOne(
      { email: FIRST_EMAIL },
      {
        $set: { email: FIRST_EMAIL, role: "admin", status: "active", passwordHash, updatedAt: now },
        $setOnInsert: { createdAt: now },
      },
      { upsert: true },
    );
  }
  console.log(
    `user ${FIRST_EMAIL} → console owner${process.env.CREATE_ADMIN_USER === "true" ? " + admin" : ""}`,
  );
} else {
  console.log("FIRST_USER_EMAIL / FIRST_USER_PASSWORD unset — no user created, and nothing else can create one");
}

/*
 * The credential check does NOT run here — see `verify-install.mjs`.
 *
 * It used to, and it was wrong every single time. This script runs inside the
 * `console` container, which is attached to the `internal` network only and
 * therefore has no route to the internet at all — by design, and the whole
 * containment argument rests on it. So the check could not reach us, said
 * "could not reach", and told every correctly-installed bureau that their
 * firewall was blocking something. A check that cannot look must never report
 * a verdict, and this one reported the alarming one.
 *
 * The check now runs in the `gateway` container, which is the container that
 * will actually do the talking. That makes it a test of the real path rather
 * than of a path nothing uses.
 */

console.log("\nThe install is empty by design: no organizations, no employees, no payslips.");
await client.close();
