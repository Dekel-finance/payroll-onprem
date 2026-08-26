# Payroll platform — on-premise install

Everything the platform needs, running on a server you own: the database, the
payroll console, the back office, the automation agent, and
the connector that drives מיכפל on a Windows machine in your office.

**No payroll data leaves your building.** The one process with a route to the
internet is a gateway that replaces identifying values with placeholders before
any text reaches a model vendor, and puts the real values back in the answer.
The applications are on a Docker network with no route out at all — not by
policy, by construction: a call that skipped the gateway would fail to resolve.

[עברית](README.he.md) · [Illustrated guide](https://onprem.dekel.io) · Version 1.1.11

---

## Before you start

| | Minimum | Comfortable |
|---|---|---|
| CPU | 4 cores, **with AVX** | 8 cores |
| RAM | 8 GB | 16 GB |
| Disk | 40 GB free | 100 GB SSD |
| OS | Linux with Docker Engine 24+ and Compose v2.20+ | Ubuntu 22.04 / 24.04 LTS |

**AVX is not optional and not a performance note.** MongoDB 5.0 and later are
compiled with those instructions, so a CPU without them does not run the
database slowly — it does not run it at all. The container exits at startup
saying:

```
WARNING: MongoDB 5.0+ requires a CPU with AVX support, and your current system
does not appear to have that!
```

Every server CPU since about 2011 has AVX, so this is almost never the hardware.
It is a virtual machine presenting a generic CPU model — `qemu64`, `kvm64`, an
old Hyper-V compatibility level — that hides the flag the host really has. Set
the guest's CPU model to `host` (or `host-passthrough`) and it appears.
`./install.sh check` tests for it before anything is written.

You also need:

- **No inbound access from the internet at all**, and **outbound HTTPS to at
  most four destinations** — put these in your egress allow-list and deny the
  rest:

  | Destination | Why | Required |
  |---|---|---|
  | `dekelmichpalil.azurecr.io` | software images | **yes** |
  | `dekel.sh` | this install reports its health, and collects your inbound email | **yes** |
  | `broker.dekel.io` | AI, reached only by the gateway | only with AI features |

  **Your server never contacts an AI vendor directly.** It calls our broker,
  which holds the vendor keys and makes that call — so there is no vendor
  credential on this machine and nothing here to rotate. What the broker
  receives has already had identity numbers, email addresses, phone numbers and
  names replaced by the gateway on your side.
- **The install id and token we send you.** Two lines. The installer generates
  everything else.
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

INSTALL_ID=<the id we sent>  INSTALL_TOKEN=<the token we sent>  ./install.sh install
```

**The id and the token are the only two values we send you, and they are not
optional.** One token does two jobs: this install reports its health to us with
it, and it **collects your inbound email** with it. Without them the software
runs, reports nothing and receives no mail — silently, which is exactly why the
installer now checks them and tells you.

### Or hand it to a coding agent

If your IT team uses Claude Code, Cursor or similar, this is one paste. Fill in
the four values first — the agent cannot invent them and should not try.

```text
Install the Dekel payroll on-prem bundle on this machine, from this repo.

Values I am giving you (do not invent or substitute these):
  SITE_ADDRESS  = <the hostname staff will type, e.g. payroll.acme.local>
  INSTALL_ID    = <the id Dekel sent us>
  INSTALL_TOKEN = <the token Dekel sent us>
  AGENCY_NAME   = <our bureau's name, as it should appear in the app>

Do this, in order, and stop and tell me if a step does not do what it says:

1. Run ./install.sh check and report anything it says is missing.
2. Run:
     INSTALL_ID=<id> INSTALL_TOKEN=<token> SITE_ADDRESS=<host> \
     AGENCY_NAME=<name> ./install.sh install
   It generates every secret into .env. It must run ONCE. NATIONAL_ID_KEYS in
   that file seals every identity number we will ever store — if it is
   regenerated later, all of them become unreadable. Never re-run the secret
   generation over an existing .env.
3. Leave every other value at its default. The control plane and the AI broker
   addresses are built into the image on purpose; a blank means "use the
   default", not "disabled".
4. Read the installer's last lines back to me. It checks our token and prints
   one of: verified / REFUSED (401) / SUSPENDED (403) / could not reach. A
   failure does NOT stop the install, but tell me which one it was — it decides
   what I have to fix.
5. Run ./install.sh status and confirm every service is healthy.

6. Read back the "Sign in" block it prints last — the console address, the
   email and the password. Do not invent these; the installer generated them.

Then remind me to copy .env somewhere off this machine. Do not commit .env
anywhere. Do not load any demo or sample data.
```

The installer asks you nothing. It generates the first user's address and
password, writes both into `.env`, and prints them with the address to open as
its last lines:

```text
▸ Sign in

  Console   https://payroll.acme.local

  Email     admin@payroll.acme.local
  Password  7fQx-2mVd-9Ktp

  Change the password after the first sign-in.
  Both are also in .env — back that file up off this machine.
```

Set `FIRST_USER_EMAIL` and `FIRST_USER_PASSWORD` before installing if you would
rather choose your own; the account can also be renamed from inside the console
afterwards. The whole install takes about five minutes, most of it downloading.

Its last step verifies the token against us and prints one of:

| | |
|---|---|
| `verified` | health reporting and inbound email are live |
| `REFUSED (401)` | the id and the token are not a matching pair — check both |
| `SUSPENDED (403)` | deliberate on our side; contact us |
| `could not reach` | this host cannot make outbound HTTPS — open it and re-run |

None of these stop the install. Your payroll does not depend on our permission.

**The install comes up empty** — no clients, no employees, no payslips. Your
records arrive through onboarding and the sync from your payroll system. An
install that arrived pre-filled would be rows you had to identify and delete
before you could trust anything on the screen.

### What it writes

A single file, `.env`, holding this install's secrets.

> **Back `.env` up, somewhere that is not this machine, before you go further.**
> One of the keys in it seals data at rest: it is what makes an identity number
> readable. If the file is lost, the
> data in the volumes cannot be recovered by us or by anyone else. That is the
> design — it is also irreversible.

---

## Opening it

| | Address | Who uses it |
|---|---|---|
| Console | `https://<your-server>` | the payroll office |

### Opening the port

The bundle publishes **two** ports and nothing else:

| Port | What for | Who needs to reach it |
|---|---|---|
| **443** | the console | your staff, from inside your network |
| **80** | the certificate renewal challenge | only if `<your-server>` is a public name |

Nothing needs to be reachable **from the internet**. If the server has a public
name and you want a normally-trusted certificate, port 80 has to be open for
Let's Encrypt to answer a challenge on it — otherwise leave it closed and the
install issues its own certificate instead.

On a stock Ubuntu server:

```bash
sudo ufw allow 443/tcp comment 'payroll console'
sudo ufw allow 80/tcp  comment 'certificate renewal — only for a public hostname'
sudo ufw status
```

The admin port is **not** in that list on purpose — it is bound to `127.0.0.1`,
so no browser on your network can open it and no firewall rule will change
that. See "The back office is not published" below.

If staff get a connection timeout rather than a certificate warning, the port
is closed somewhere between them and this machine — check the host firewall
first, then anything between (a hypervisor, a cloud security group, a VLAN ACL).

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

**The connector does not run on this server.** It drives מיכפל over RDP from
our own infrastructure, so there is nothing to install here and this machine
needs no route to the Windows box.

Tell us which מיכפל installation this bureau uses and we will point a connector
at it. If we ask you to set `MICHPAL_WORKER_URL` and `WORKER_TOKEN` in `.env`,
those are the address and bearer of that connector — reached over HTTPS, like
any other outside service.

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
| the applications (console, admin, and the background services) | **yes** — a few seconds each, one at a time |
| the database | **never.** A database upgrade is a data migration and is not something to do unattended at 03:00. |
| the מיכפל connector | **no**, by default. It runs one session at a time and keeps a run's state in memory, so restarting it mid-run would end that payroll run without reporting it. `./install.sh update` restarts it when you are watching. |

**To approve every update yourself** instead, set one of these in `.env` and
restart:

```bash
AUTO_UPDATE_MONITOR_ONLY=true   # it reports what it would do, and does nothing
BUNDLE_VERSION=1.1.11           # pin an exact version; updates never fire
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
2. **Aggregate telemetry**: counts, durations, error codes and hashed
   identifiers, so we can see that an install is healthy. It is checked against
   an allow-list immediately before sending — anything that is not a number, a
   timestamp, a hash or a known code is refused, so a name or an error message
   quoting a screen cannot pass by construction. `GET /snapshot` on the metrics
   service shows you exactly what would be sent, at any time.

   This is part of the install rather than a setting, and the reason is the same
   token: the one credential we send you both reports this install's health and
   **collects your inbound email**. An install that reported nothing would be one
   we could not tell was broken, and one whose clients' mail never arrived.
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
| "Provision a connector" on a מיכפל action | no connector is registered for this bureau yet — tell us and we will point one at your מיכפל. |
| A page shows nothing on any address | `SITE_ADDRESS` does not match the hostname you typed. Re-run `./install.sh bootstrap`. |
| The model refuses a document | `GATEWAY_ATTACHMENTS=block` and OCR could not read the scan. A clearer scan, or set it to `allow` knowingly. |
| Reminders never send | `./install.sh logs scheduler` — it answers 503 when a job has stopped succeeding. |

Support: **support@dekel.finance**. Include the output of `./install.sh status`
and the install id from `.env` (`METRICS_INSTALL_ID`).
