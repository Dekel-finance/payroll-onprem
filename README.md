# Payroll platform — on-premise install

Everything the platform needs, running on a server you own: the database, the
payroll console, the back office, the employee portal, the automation agent, and
the connector that drives מיכפל on a Windows machine in your office.

**No payroll data leaves your building.** The one process with a route to the
internet is a gateway that replaces identifying values with placeholders before
any text reaches a model vendor, and puts the real values back in the answer.
The applications are on a Docker network with no route out at all — not by
policy, by construction: a call that skipped the gateway would fail to resolve.

[עברית](README.he.md) · [Illustrated guide](https://onprem.dekel.io) · Version 1.1.3

---

## Before you start

| | Minimum | Comfortable |
|---|---|---|
| CPU | 4 cores | 8 cores |
| RAM | 8 GB | 16 GB |
| Disk | 40 GB free | 100 GB SSD |
| OS | Linux with Docker Engine 24+ and Compose v2.20+ | Ubuntu 22.04 / 24.04 LTS |

You also need:

- **No inbound access from the internet at all**, and **outbound HTTPS to at
  most four destinations** — put these in your egress allow-list and deny the
  rest:

  | Destination | Why | Required |
  |---|---|---|
  | `dekelmichpalil.azurecr.io` | software images | **yes** |
  | `api.anthropic.com` | AI vendor, reached only by the gateway | only with AI features |
  | `api.interfaze.ai` | **second AI vendor**, reads documents | only with document extraction |
  | your reporting endpoint | aggregate telemetry | no — blank sends nothing |

  There are **two AI vendors, not one**. An allow-list or a processing register
  that names only the well-known one is incomplete.
- **A model vendor key**, or ask us to supply one.
- *Optional:* the **Windows machine running מיכפל**, reachable from this server
  on port 3389. Without it everything else still works; the connector simply
  does not start.

Check the machine before installing anything:

```bash
./install.sh check
```

It reports what is missing and writes nothing.

---

## Install

```bash
git clone https://github.com/Dekel-finance/payroll-onprem.git
cd payroll-onprem

./install.sh install
```

The installer asks for an email address and a password for the first
administrator, then prints the three addresses to open. It takes about five
minutes, most of it downloading.

**The install comes up empty** — no clients, no employees, no payslips. Your
records arrive through onboarding and the sync from your payroll system. An
install that arrived pre-filled would be rows you had to identify and delete
before you could trust anything on the screen.

### What it writes

A single file, `.env`, holding this install's secrets.

> **Back `.env` up, somewhere that is not this machine, before you go further.**
> Two of the keys in it seal data at rest: one encrypts every employee document,
> the other is what makes an identity number readable. If the file is lost, the
> data in the volumes cannot be recovered by us or by anyone else. That is the
> design — it is also irreversible.

---

## Opening it

| | Address | Who uses it |
|---|---|---|
| Console | `https://<your-server>:4201` | the payroll office |
| Portal | `https://<your-server>:4401` | employees |

### The certificate warning, and why it is there

On first visit the browser will warn that the certificate is not trusted. It is
issued by a small certificate authority that runs inside your own install,
because a public authority like Let's Encrypt cannot issue a certificate for a
name on a private network — it has to reach the server from the internet, which
is precisely what this deployment avoids.

Fix it once, per machine. Export the root certificate:

```bash
docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt .
```

then install it as a trusted root authority:

- **Windows** — double-click `root.crt` → Install Certificate → Local Machine →
  Place all certificates in the following store → **Trusted Root Certification
  Authorities**. Group Policy can push it to every machine at once.
- **macOS** — open it in Keychain Access → System → set it to *Always Trust*.
- **Linux** — copy to `/usr/local/share/ca-certificates/` and run
  `sudo update-ca-certificates`.
- **iOS / Android** — mail the file to the device and install it as a profile.

Plain HTTP is not an option, and the reason is worth knowing: the applications
mark their session cookie `Secure`, and browsers discard a Secure cookie that
arrives over `http://`. Over HTTP the login page accepts the password, redirects,
and returns you to the login page for ever, without an error anywhere.

If the server does have a public hostname, set `SITE_ADDRESS` to it and
`CADDYFILE=Caddyfile.public` in `.env`, and a normal certificate is obtained
automatically. Port 80 must be reachable for the check.

---

## Connecting מיכפל

The connector drives מיכפל over RDP on a Windows machine on your network.

1. In `.env`, set `RDP_HOST` to that machine's address, and `RDP_USER` /
   `RDP_PASS` to an account that can sign into it.
2. `docker compose --profile michpal up -d`

One run at a time, deliberately: a Windows machine gives one interactive session
per user, and two automations sharing one desktop interfere with each other in
ways that are expensive to recover from.

> **The automation is calibrated against our מיכפל installation.** It recognises
> screens by their pixels, so a different version, a different screen resolution
> or a different company book may need recalibration. Plan a session with us for
> this rather than discovering it during a payroll run.

---

## Updates

The install checks for a new version **every ten minutes** and applies it on its
own. There is nothing to run.

It follows the `stable` channel — the release we have blessed, not whatever
built most recently — so an update only happens when we decide one should. What
gets restarted is deliberately narrow:

| | updates by itself |
|---|---|
| the applications (console, admin, portal, and the background services) | **yes** — a few seconds each, one at a time |
| the database | **never.** A database upgrade is a data migration and is not something to do unattended at 03:00. |
| the מיכפל connector | **no**, by default. It runs one session at a time and keeps a run's state in memory, so restarting it mid-run would end that payroll run without reporting it. `./install.sh update` restarts it when you are watching. |

**To approve every update yourself** instead, set one of these in `.env` and
restart:

```bash
AUTO_UPDATE_MONITOR_ONLY=true   # it reports what it would do, and does nothing
BUNDLE_VERSION=1.1.3            # pin an exact version; updates never fire
```

Either way `./install.sh update` applies the current release immediately.

> The updater needs access to the Docker service on this machine, which in
> practice makes it as privileged as the administrator account. That is the cost
> of unattended security patching on a server nobody logs into. If your security
> policy does not allow it, use `AUTO_UPDATE_MONITOR_ONLY=true` and update by
> hand.

## Running it

```bash
./install.sh status     # what is running, and the addresses
./install.sh logs       # follow everything;  ./install.sh logs console  for one
./install.sh backup     # database + documents, into ./backups/<timestamp>/
./install.sh update     # pull a newer version and restart
./install.sh stop       # stop; your data is untouched
```

### Backups

`./install.sh backup` writes two files: a database dump and an archive of the
stored documents. You need both — a database restored without the documents
gives you an install where every employee exists and none of their files open.

Neither can be read without `.env`. Keep that copy somewhere else: an archive
sitting beside the key it is encrypted with is one theft, not two.

---

## What leaves your network

Three things, and nothing else:

1. **Model requests**, through the gateway, with identifying values replaced by
   placeholders (`[PII:ID:1]`) and restored in the answer. Documents are read
   *on this server* — a PDF becomes text here, and only the pseudonymised text
   crosses. What a scan does not yield to OCR is refused rather than forwarded.
2. **Aggregate telemetry**, if you enable it: counts, durations, error codes and
   hashed identifiers, so we can see that an install is healthy. It is checked
   against an allow-list immediately before sending — anything that is not a
   number, a timestamp, a hash or a known code is refused, so a name or an error
   message quoting a screen cannot pass by construction. `GET /snapshot` on the
   metrics service shows you exactly what would be sent. Leave
   `BETTERSTACK_*` blank and nothing is reported at all.
3. **Image downloads**, when you install or update.

There is no remote access channel. We cannot reach into this install; if you
want us to look at something, you send us what you choose to send.

---

## If something is wrong

```bash
./install.sh logs <service>
```

| Symptom | Where to look |
|---|---|
| The login page returns to itself | You are on `http://`. See the certificate section above. |
| "Provision a connector" on a מיכפל action | `RDP_HOST` is unset, or `./install.sh bootstrap` has not run. |
| The portal shows nothing on any address | `SITE_ADDRESS` does not match the hostname you typed. Re-run `./install.sh bootstrap`. |
| The model refuses a document | `GATEWAY_ATTACHMENTS=block` and OCR could not read the scan. A clearer scan, or set it to `allow` knowingly. |
| Reminders never send | `./install.sh logs scheduler` — it answers 503 when a job has stopped succeeding. |

Support: **support@dekel.finance**. Include the output of `./install.sh status`
and the install id from `.env` (`METRICS_INSTALL_ID`).
