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
 *   2. the portal host   — `portal_tenants`. The portal resolves the bureau from
 *                          the Host header and refuses an unregistered one, so
 *                          without this row it serves employees nothing at all.
 *   3. the connector     — `console_michpal_workers`. `resolveWorker()` refuses
 *                          an agency with no row rather than falling back to a
 *                          shared worker (PAY-66) — correct in the cloud, where
 *                          the shared worker is ours; on-prem it means the
 *                          console answers "provision a connector" while the
 *                          connector runs two containers away.
 *   4. the first user    — `console_users`. The console signs a user in with a
 *                          password or an emailed one-time code, and on-prem
 *                          there is no mail sender configured and no row to send
 *                          a code to: the login page is correct, reachable and
 *                          unusable.
 *
 *                          It does NOT create an `admin_users` row. The admin
 *                          application is the supplier's back office, its port
 *                          is bound to loopback, and the person running a
 *                          bureau has no business signing into it. An install
 *                          the supplier operates itself sets
 *                          `CREATE_ADMIN_USER=true`.
 *
 * Idempotent — every write is an upsert keyed on something stable, so running it
 * again after a version bump repairs a missing row without touching the rest.
 *
 *   docker compose cp register-install.mjs console:/app/register-install.mjs
 *   docker compose exec -T \
 *     -e AGENCY_NAME='לשכת …' -e PORTAL_HOST=payroll.example.local \
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
const BASE_URL = (process.env.MICHPAL_WORKER_URL ?? "http://michpal-worker:8080").replace(/\/+$/, "");
const TOKEN = process.env.WORKER_TOKEN ?? process.env.MICHPAL_WORKER_TOKEN ?? "";

const AGENCY_NAME = (process.env.AGENCY_NAME ?? "").trim() || "הלשכה";
const FIRST_EMAIL = (process.env.FIRST_USER_EMAIL ?? "").trim().toLowerCase();
const FIRST_PASSWORD = process.env.FIRST_USER_PASSWORD ?? "";

/**
 * The portal strips the port before looking a host up, so one row covers every
 * port the bundle publishes. Scheme and path are tolerated on the way in
 * because SITE_ADDRESS is sometimes pasted as a URL.
 */
const PORTAL_HOST = (process.env.PORTAL_HOST ?? process.env.SITE_ADDRESS ?? "")
  .trim()
  .toLowerCase()
  .replace(/^https?:\/\//, "")
  .split("/")[0]
  .split(":")[0];

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
    $set: { name: AGENCY_NAME, ownerEmail: FIRST_EMAIL, status: "active" },
    // The ingest bearer is generated once and never rotated by a re-run — a new
    // value here would silently break whatever is already pushing with the old.
    $setOnInsert: { apiKey: randomBytes(24).toString("hex"), provisionedAt: now },
  },
  { upsert: true },
);
// The console's own settings doc. `loadSettings` falls back to defaults when it
// is missing, so this exists to carry the NAME — the one thing a default cannot
// guess and the office sees on every screen.
await db.collection("console_office").updateOne(
  { _id: agencyId },
  { $set: { agencyId, agencyName: AGENCY_NAME, updatedAt: now } },
  { upsert: true },
);
console.log(`agency ${agencyId}  "${AGENCY_NAME}"`);

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

// ── 3. the portal hostname ──────────────────────────────────────────────────
if (!PORTAL_HOST) {
  console.log("PORTAL_HOST unset — no portal tenant; the portal will 404 on every host");
} else {
  // One host, one bureau: a second agency claiming the same hostname would make
  // the lookup order decide whose payslips a browser sees.
  await db.collection("portal_tenants").updateOne(
    { host: PORTAL_HOST },
    {
      $set: { agencyId, host: PORTAL_HOST, status: "active", branding: { displayName: AGENCY_NAME } },
      $setOnInsert: { createdAt: now },
    },
    { upsert: true },
  );
  console.log(`portal → ${PORTAL_HOST}`);
}

// ── 4. the first user ───────────────────────────────────────────────────────
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
  // Back-office access, and only where the supplier is the operator. On an
  // ordinary install the admin port is bound to loopback (docker-compose.yml)
  // and no admin user exists — two independent reasons a screen that was never
  // meant for the bureau cannot be opened by it.
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

console.log("\nThe install is empty by design: no organizations, no employees, no payslips.");
await client.close();
