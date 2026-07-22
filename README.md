# attackbox-ansible

Ansible that turns a fresh **Kali**, **Parrot**, **Debian**, or **Ubuntu** host
into a loaded pentest / red-team box, with an encrypted work volume and a mix of
source-built and packaged tooling.

This is a modernized rebuild of the original single-file playbook. The big
changes:

- **eCryptFS → gocryptfs.** The encrypted `/opt` no longer overlays itself; a
  separate cipher directory holds the encrypted blobs.
- **Fast-moving tools are built from source; stable ones come from packages.**
- **Runs on Debian/Ubuntu without Kali repos.** The offensive toolset only
  exists in the Kali/Parrot repos, so on Debian/Ubuntu those tools are built
  from source (pipx / `go install` / gem / release binary / git) — we never mix
  Kali repos into a Debian/Ubuntu host.
- **Metasploit** tracks the official **Rapid7 nightly** build.
- Restructured into proper Ansible **roles** with a **Docker-based test suite**
  (Kali + Parrot + Debian + Ubuntu) and CI.

---

## Quick start

```bash
# 1. Install the required collections on the control node
ansible-galaxy collection install -r requirements.yml

# 2. Point the inventory at your box (connect as root)
$EDITOR inventory.list

# 3. Build it
ansible-playbook -i inventory.list playbook.yml

# Faster build that skips the heavy source compiles / Empire installer:
ansible-playbook -i inventory.list playbook.yml --skip-tags heavy
```

Supported targets: Kali rolling, Parrot Security, Debian stable, and Ubuntu LTS.
Connect as `root`; set `attackbox_become=true` in the inventory if you connect as
a sudo user instead.

### How tools are chosen per distro

Ansible facts (`ansible_distribution`) pick the install path automatically:

| | Kali | Parrot / Debian / Ubuntu |
| --- | --- | --- |
| System tools (nmap, hydra, smbclient…) | apt | apt |
| Offensive tools (mitm6, netexec, nuclei…) | apt (native packages) | source (pipx / `go install` / gem / release binary / git) |
| Tools not packaged anywhere (kerbrute, pypykatz, ldapdomaindump…) | source | source |

Only **Kali** packages the full offensive toolset, so only Kali uses apt for it.
Parrot's offensive packaging is incomplete (e.g. `mitm6` isn't there), so Parrot
uses the same source path as Debian/Ubuntu. No Kali repositories are ever added
to a non-Kali host. (BloodHound's GUI + neo4j remain Kali-apt only; the
`bloodhound-ce` collector is installed everywhere.)

---

## The encrypted volume (gocryptfs)

eCryptFS mounted `/opt` onto itself. gocryptfs can't do that — it needs a
separate cipher directory and a plaintext mountpoint:

| Path | Role |
| --- | --- |
| `/opt-encrypted` | cipher dir — encrypted blobs on the real disk |
| `/opt` | plaintext mountpoint — where you and the tools see files |

Everything **source-built** lands in `/opt`, so it is encrypted at rest.
Packaged tools install to `/usr` and stay usable even when `/opt` is unmounted —
so the box still boots and functions with only your source tools + loot sealed.

**Key handling** (see `group_vars/all.yml`):

- A random 32-char passphrase is generated per host. Ansible writes it to
  `credentials/<host>/gocryptfs.txt` on the **control node** (git-ignored — keep
  it safe) and returns it to the play.
- By default (`gocryptfs_store_key_on_target: true`) a root-only copy is dropped
  at `/root/.attackbox/gocryptfs.key` and a systemd unit
  (`attackbox-opt.service`) auto-mounts `/opt` on boot. Convenient, but the key
  on disk means a powered-off seizure with root-fs access can recover it.
- Set `gocryptfs_store_key_on_target: false` for a stronger posture: the key
  never touches the target, and you mount manually each boot with
  `/root/mount-opt.sh` (it prompts for the passphrase).

Mount/unmount manually any time:

```bash
/root/mount-opt.sh                 # mount
fusermount3 -u /opt                # unmount
```

---

## What gets installed

### Source-built (into encrypted `/opt`, tracking upstream master)

These iterate faster than distro maintainers keep up, so the distro package (if
any) is removed first and the source build owns the command name on `PATH`.

| Tool | Source | Notes |
| --- | --- | --- |
| Impacket | `fortra/impacket` | `pipx install --editable`; `impacket-*` scripts |
| NetExec | `Pennyw0rth/NetExec` | `pipx install --editable`; `nxc` |
| Responder | `lgandx/Responder` | PATH wrapper |
| sqlmap | `sqlmapproject/sqlmap` | PATH symlink |
| nikto | `sullo/nikto` | PATH symlink |
| hashcat | `hashcat/hashcat` | compiled incl. Rust bridge plugins (`heavy`) |
| John the Ripper | `openwall/john` (jumbo) | compiled with full format libs incl. `crypt(3)` (`heavy`) |
| PowerShell Empire | `BC-SECURITY/Empire` | cloned; `setup/install.sh` (`heavy`, optional — `empire_install`) |

### Rapid7 nightly

- **Metasploit Framework** from `apt.metasploit.com` (pinned above the distro
  package), installed to `/opt/metasploit-framework`.

### AD / relay / credential / recon tooling

Installed from apt on Kali/Parrot and from source on Debian/Ubuntu (see the
per-distro table above):

- **AD & relaying:** `mitm6`, `krbrelayx`, `coercer`, `bloodyAD`, `certipy`,
  `ldapdomaindump`, `adidnsdump`, `pywerview`, `enum4linux-ng`, `kerbrute`,
  `targetedKerberoast`, BloodHound CE collector (`bloodhound-ce`)
- **Credential looting:** `pypykatz`, `lsassy`, `DonPAPI`, `hekatomb`
- **C2:** `sliver` (in addition to Metasploit + Empire)
- **Recon:** `subfinder`, `dnsx`, `naabu`, `httpx`, `nuclei`, `gowitness`,
  `theHarvester`, `dirsearch`, `ffuf`, `feroxbuster`, `gobuster`
- **Pivoting:** `chisel`, `ligolo-ng`, `sshuttle`, `proxychains4`
- **Cloud (Azure/M365):** `roadrecon` (ROADtools)
- **Web:** `sqlmap`, `nikto`, `wpscan`, `evil-winrm`, `mitmproxy`, `padbuster`
- **System:** `nmap`, `ncat`, `smbclient`, `cifs-utils`, `nfs-common`,
  `ldap-utils`, `whois`, `tcpdump`, `bind9-dnsutils`, `hydra`

### Windows resources (`roles/windows_resources`)

Precompiled Windows binaries. On Kali/Parrot via `kali-tools-windows-resources`;
on Debian/Ubuntu cloned/downloaded into `/usr/local/share/attackbox/windows-resources`:
SharpCollection (Rubeus/SharpHound/Seatbelt/Certify), PowerSploit, PEASS-ng
(winPEAS/linPEAS), and the latest mimikatz release. (`heavy` tag — bulky.)

### Reference data (cloned OUTSIDE the encrypted volume)

To save space in the encrypted volume, big public data repos clone to
`/usr/local/share/attackbox`: `PayloadsAllTheThings`, `post-exploitation`, and
(on Debian/Ubuntu) `SecLists`. On Kali/Parrot SecLists is the `seclists` package
at `/usr/share/seclists`.

Move any tool between "source" and "package" by editing the lists in the role
`defaults/` (`tools_packages`, `tools_source`).

---

## Layout

```
playbook.yml                 top-level play (bootstrap + roles)
group_vars/all.yml           operator config (paths, toggles, key handling)
roles/
  common/                    repos + base packages + build deps
  gocryptfs/                 encrypted /opt (init, mount, systemd unit)
  tools_packages/            distro-packaged tools
  metasploit/                Rapid7 nightly
  tools_source/              source builds + Debian/Ubuntu source installs (pipx/go/gem/git)
  empire/                    PowerShell Empire (BC Security)
  reference_data/            PayloadsAllTheThings, post-exploitation, SecLists
  windows_resources/         SharpCollection, PowerSploit, PEASS-ng, mimikatz
  dotfiles/                  .screenrc, .tmux.conf
  ssh_hardening/             optional (harden_ssh: true)
test/                        docker test harness (see below)
```

### Useful tag selections

```bash
ansible-playbook ... --tags crypto            # just (re)mount the encrypted volume
ansible-playbook ... --tags source            # just the source-built tools
ansible-playbook ... --tags impacket,netexec  # single tools
ansible-playbook ... --skip-tags heavy        # skip compiles + Empire installer
```

---

## Testing

The harness spins up disposable **Kali**, **Parrot**, **Debian**, and **Ubuntu**
containers, runs the playbook against them over Ansible's docker connection (no
SSH), then asserts the result with `test/verify.yml`. All tool installs happen
**inside** the containers.

```bash
test/run.sh kali smoke      # fast: skips heavy builds
test/run.sh debian smoke    # exercises the Debian/Ubuntu source path
test/run.sh ubuntu smoke
test/run.sh all full        # every distro, everything (slow; downloads + compiles)
KEEP=1 test/run.sh debian smoke   # leave the container up for debugging
```

gocryptfs needs FUSE, so the containers run with
`--cap-add SYS_ADMIN --device /dev/fuse --security-opt apparmor=unconfined
--security-opt seccomp=unconfined` (works on GitHub Actions runners too).

CI (`.github/workflows/ci.yml`) runs the smoke test on both distros for every
push/PR; a `full` run is available via **workflow_dispatch**.

---

## Security notes

- `credentials/` (control-node passphrases) is git-ignored — **never commit it**.
- The default configuration favors operator convenience (auto-mount, key on
  box). Flip `gocryptfs_store_key_on_target` for a stronger at-rest posture.
- This builds offensive tooling. Use it only on systems you are authorized to
  test.
