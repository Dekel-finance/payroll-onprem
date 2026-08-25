/**
 * Does the control plane accept this install's credentials?
 *
 *     docker compose exec gateway node /app/verify-install.mjs
 *
 * ## Why this runs at all
 *
 * `METRICS_INSTALL_TOKEN` is what this box uses for two things: pushing its
 * health to us, and **collecting its inbound mail**. Both fail with a 401 that
 * nothing surfaces — the metrics container logs it every fifteen minutes and
 * the mail poll simply returns nothing, so a wrong token looks exactly like a
 * quiet week. One install ran that way before anybody noticed.
 *
 * So the token is exercised once, while somebody is still watching the
 * terminal. It is the difference between "you pasted the wrong value" and "the
 * customer's email stopped arriving and nobody knows why".
 *
 * ## Why it runs HERE and not in the console
 *
 * It used to run inside `register-install.mjs`, in the `console` container —
 * which is on the `internal` network only and has **no route to the internet at
 * all**. That is deliberate and is what the containment promise rests on. The
 * consequence was that the check could never succeed: every correctly-installed
 * bureau was told "could not reach", and the one message that means "your
 * firewall is blocking us" was printed to people whose firewall was fine.
 *
 * The gateway is the container that will actually do this talking. Running the
 * check here tests the path that is used rather than one that is not.
 *
 * ## Why it does not fail the install
 *
 * A WARNING, not an exit code. Nothing on this box needs our permission to run
 * payroll, and an install that refused to finish because a firewall rule was
 * late would be a bureau unable to pay salaries over a network rule.
 */

const id = (process.env.METRICS_INSTALL_ID ?? "").trim();
const token = (process.env.METRICS_INSTALL_TOKEN ?? "").trim();

// Same resolution the metrics container uses: the address is compiled in, so an
// operator who set nothing is still checked against the real thing.
const raw = (process.env.METRICS_CONTROL_PLANE_URL ?? "").trim();
if (raw.toLowerCase() === "off") {
  console.log("\ncontrol plane: opted out (METRICS_CONTROL_PLANE_URL=off) — this install will not report");
  process.exit(0);
}
const base = (raw || "https://dekel.sh/api").replace(/\/+$/, "");

if (!id || !token) {
  console.log(`\n⚠ no METRICS_INSTALL_${!id ? "ID" : "TOKEN"} — this install will not report its health,`);
  console.log("  and it will not receive any inbound email. Ask us for both, put them in .env,");
  console.log("  and re-run this script.");
  process.exit(0);
}

// The mail endpoint rather than the snapshot one: same credential, same
// registry, but a GET that parks nothing — so a verification does not write a
// row that looks like a real push.
const url = `${base}/v1/installs/${encodeURIComponent(id)}/mail?after=0&wait=0`;
let res;
try {
  res = await fetch(url, {
    headers: { authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(20_000),
  });
} catch (err) {
  console.log(`\n⚠ could not reach ${base} — ${err.message}`);
  console.log("  The install works, but it cannot report health or collect email until this");
  console.log("  container can make outbound HTTPS requests. Check the firewall, then re-run:");
  console.log("    docker compose exec gateway node /app/verify-install.mjs");
  process.exit(0);
}

if (res.ok) {
  console.log(`\n✓ control plane: ${id} verified at ${base}`);
  console.log("  Health reporting and inbound email are live.");
  process.exit(0);
}

if (res.status === 401) {
  console.log(`\n✗ control plane REFUSED this install (401).`);
  console.log(`  Either "${id}" is not an install we know, or the token does not match it.`);
  console.log("  Both come from us as a pair — check METRICS_INSTALL_ID and METRICS_INSTALL_TOKEN.");
  process.exit(0);
}

if (res.status === 403) {
  console.log(`\n✗ control plane says this install is SUSPENDED (403).`);
  console.log("  That is deliberate on our side, not a configuration error. Contact us.");
  process.exit(0);
}

/*
 * 409 — the credentials are GOOD and the mailbox is not open yet.
 *
 * The endpoint refuses to hand over mail for an install whose public key it
 * does not hold, and the gateway publishes that key when it boots. So a
 * verification run in the seconds after `up -d` legitimately lands here, and
 * the previous behaviour — printing the generic "answered 409, health and email
 * may not work" — turned the most ordinary moment in an install into a warning.
 *
 * Authentication has already been proved by the time the endpoint can answer
 * this at all, which is the thing this script exists to test. Said plainly, with
 * what to do if it does not resolve itself.
 */
if (res.status === 409) {
  console.log(`\n✓ control plane: ${id} verified at ${base} — the token is good.`);
  console.log("  The mailbox is not open yet: the gateway publishes this install's public key");
  console.log("  when it starts, and that has not been recorded on our side yet. It normally");
  console.log("  resolves within a minute. If it does not:");
  console.log("    docker compose logs gateway | grep -i mail");
  process.exit(0);
}

console.log(`\n⚠ control plane answered ${res.status} — health and email may not work. Re-run to retry.`);
