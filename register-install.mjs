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
const BASE_URL = (process.env.MICHPAL_WORKER_URL ?? "http://michpal-worker:8080").replace(/\/+$/, "");
const TOKEN = process.env.WORKER_TOKEN ?? process.env.MICHPAL_WORKER_TOKEN ?? "";

const AGENCY_NAME = (process.env.AGENCY_NAME ?? "").trim() || "הלשכה";
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
 * The credential check, last — after the install is otherwise usable.
 *
 * ## Why this runs at all
 *
 * `METRICS_INSTALL_TOKEN` is what this box uses for two things: pushing its
 * health to us, and **collecting its inbound mail**. Both fail with a 401 that
 * nothing surfaces — the metrics container logs it every fifteen minutes and
 * the mail poll simply returns nothing, so a wrong token looks exactly like a
 * quiet week. One install ran for weeks that way before anybody noticed.
 *
 * So the token is exercised here, once, while somebody is still watching the
 * terminal. It is the difference between "you pasted the wrong value" and "the
 * customer's email stopped arriving and nobody knows why".
 *
 * ## Why it does not fail the install
 *
 * This is deliberately a WARNING, not an exit code. Nothing on this box needs
 * our permission to run payroll, and an install that refused to finish because
 * a firewall had not been opened yet would be a bureau unable to pay salaries
 * over a network rule. Authorization, where it is wanted, belongs on our side
 * of a call — see the broker's entitlements — not in a setup script the
 * customer administers.
 */
async function verifyControlPlane() {
  const id = (process.env.METRICS_INSTALL_ID ?? "").trim();
  const token = (process.env.METRICS_INSTALL_TOKEN ?? "").trim();
  // Same resolution the metrics container uses: the address is compiled in, so
  // an operator who set nothing still gets checked against the real thing.
  const raw = (process.env.METRICS_CONTROL_PLANE_URL ?? "").trim();
  if (raw.toLowerCase() === "off") {
    console.log("\ncontrol plane: opted out (METRICS_CONTROL_PLANE_URL=off) — this install will not report");
    return;
  }
  const base = (raw || "https://dekel.sh/api").replace(/\/+$/, "");

  if (!id || !token) {
    console.log(`\n⚠ no METRICS_INSTALL_${!id ? "ID" : "TOKEN"} — this install will not report its health,`);
    console.log("  and it will not receive any inbound email. Ask us for both, put them in .env,");
    console.log("  and re-run this script.");
    return;
  }

  // The mail endpoint rather than the snapshot one: it is the same credential
  // and the same registry, but a GET that parks nothing, so a verification does
  // not write a row that looks like a real push.
  const url = `${base}/v1/installs/${encodeURIComponent(id)}/mail?after=0&wait=0`;
  let res;
  try {
    res = await fetch(url, {
      headers: { authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(20_000),
    });
  } catch (err) {
    console.log(`\n⚠ could not reach ${base} — ${err.message}`);
    console.log("  The install works, but it cannot report health or collect email until this host");
    console.log("  can make outbound HTTPS requests. Check the firewall, then re-run this script.");
    return;
  }

  if (res.ok) {
    console.log(`\n✓ control plane: ${id} verified at ${base}`);
    console.log("  Health reporting and inbound email are live.");
    return;
  }
  if (res.status === 401) {
    console.log(`\n✗ control plane REFUSED this install (401).`);
    console.log(`  Either "${id}" is not an install we know, or the token does not match it.`);
    console.log("  Both come from us as a pair — check METRICS_INSTALL_ID and METRICS_INSTALL_TOKEN.");
    return;
  }
  if (res.status === 403) {
    console.log(`\n✗ control plane says this install is SUSPENDED (403).`);
    console.log("  That is deliberate on our side, not a configuration error. Contact us.");
    return;
  }
  console.log(`\n⚠ control plane answered ${res.status} — health and email may not work. Re-run to retry.`);
}

await verifyControlPlane();

console.log("\nThe install is empty by design: no organizations, no employees, no payslips.");
await client.close();
