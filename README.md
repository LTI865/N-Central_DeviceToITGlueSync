# N-central to IT Glue Device Sync

A PowerShell script that copies devices (computers and servers) from **N-able N-central** into
**IT Glue** as Configurations, built to run unattended from Windows Task Scheduler.

```
N-central (devices only)  >  IT Glue (devices, customers, sites, contacts)  >  Halo
```

N-central is the source of truth for devices. IT Glue is the source of truth for customers,
sites and contacts, so this script **never creates, renames or changes an IT Glue organization
or location**. It only creates and updates IT Glue Configurations, and it never deletes or
archives anything.

> **Status: v0.11, not yet tested against live N-central or IT Glue.** The N-central field names
> (especially the hardware details from `/api/devices/{id}/assets`) are based on N-able's API
> documentation and need checking on the first dry run. Follow "First run" below. The optional
> local AI model mode (v0.4) has not been run against Ollama yet either.

## The key rule: customer and site must match

| N-central | must match in IT Glue |
|---|---|
| Customer name | an organization with the same name (case and extra spaces ignored) |
| Site name (if the device is under a site) | one of that organization's locations, same name |
| No site (device directly under the customer) | the organization must have exactly one location |

A device that doesn't match is **not synced**. It's reported, and an email goes out, the same way
the IT Glue health monitor alerts:

- one finding per N-central customer (or site) that doesn't match, listing its devices;
- a message only when the set of problems changes, plus a reminder every `ReminderHours` (24);
- a "sync can't run" alert on the first failed run (bad token, N-central or IT Glue down), then
  every `ReminderHours` while it keeps failing, and a message when it's running again.

The other devices still sync. To make **no changes at all** while any device doesn't match, set
`Sync.BlockAllOnMismatch` to `true`.

If a customer's names can't be made the same, map them in `CustomerNameMap`
(`"N-central name": "IT Glue name"`). To leave a customer out on purpose (for example your own
internal one), use `NCentral.ExcludeCustomerIds` or `ExcludeCustomerNames`.

## What it checks and reports

| # | Check | Means |
|---|-------|-------|
| 1 | Customer | N-central customer has no IT Glue organization with that name (or more than one), or the device is at service-organization level. |
| 2 | Site | N-central site has no IT Glue location with that name in the matched organization, or the device has no site and the organization doesn't have exactly one location. |
| 3 | Can't match safely | Creating or renaming would make a duplicate (see "No duplicates"); two N-central devices with the same serial or name in the same customer (the older one is skipped and the newest check-in wins); several IT Glue configurations in the same organization with the same serial or name; the device moved customer in N-central; or IT Glue keeps ignoring an update after `MaxRetries` (3). Nothing is changed for these. |
| 4 | IT Glue refused | A create or update was refused (with IT Glue's error). Retried next run. |
| 5 | Gone from N-central | A device synced before is no longer in N-central. Report only by default; `RetiredDeviceAction: "SetStatus"` sets its status to `RetiredStatus` instead. |
| 6 | Local AI: check this match | Only with the local AI model on. The model thinks a new N-central device may be an existing IT Glue configuration with a different name, but isn't sure enough to link it. The device is held (not created). Also: the model isn't available this run, or an `ApprovedMatches` entry is wrong. |
| 7 | Local AI: consider archiving | Only with the local AI model on. An IT Glue computer/server record that no N-central device is linked to and that the model thinks is retired. A suggestion only; the script never archives. |

## How a device is matched to an IT Glue configuration

1. The configuration it was linked to before (saved in `sync-state.json`).
2. Otherwise a configuration in the **same organization** with the same **serial number**.
   Placeholder serials like "To Be Filled By O.E.M." are ignored (`IgnoreSerials`).
3. Otherwise one in the same organization with the same **name or hostname**, if the serial
   numbers don't disagree (`Sync.MatchByName`).
4. Optional, only with the local AI model on: the model is asked whether one of the customer's
   existing configurations is the same device under a different name (see below).
5. Otherwise a new configuration is created. A new device waits until its serial number has been
   read from N-central, so it isn't created twice.

What's written:

| IT Glue field | From N-central | On create | On update (default `UpdateFields`) |
|---|---|---|---|
| Name | device name | yes | yes |
| Hostname | discovered name | yes | yes |
| Serial number | asset details | yes | yes |
| Configuration type | device class via `DeviceClassMap` (Server, Laptop, Workstation) | yes | yes |
| Location | matched site | yes | yes |
| OS notes | reported OS | yes | yes |
| Manufacturer / Model | asset details, only if that manufacturer/model already exists in IT Glue | yes | yes |
| MAC address / Primary IP | first network adapter with an IPv4 address | yes | no (they change often; add `mac-address`, `primary-ip` to `UpdateFields` to keep them updated) |
| Status | `Sync.ConfigurationStatus` (Active) | yes | no |

A value that is blank in N-central never clears IT Glue. The organization of an existing
configuration is never changed. Devices whose class isn't in `DeviceClassMap` (printers, network
devices, probes...) are skipped.

## Optional: local AI model (Ollama)

Off by default. Turn it on for one run with `-UseLocalModel`, or for the scheduled task with
`"LocalModel": { "Enabled": true }` in the config. It needs [Ollama](https://ollama.com) running on
the same computer (default `http://localhost:11434`) with the model pulled (default
`gemma4:12b`). The script talks to Ollama's API directly; OpenCode isn't involved.

**The script decides, the model only suggests.** Exact matching (link, serial, name) always runs
first. Only the devices still unmatched go to the model.

**Batch mode (`Mode: "Batch"`, the default since v0.9):** one question per customer instead of
one per device. The script writes the customer's leftover devices and the candidate IT Glue
records to CSV files, sends both tables in one question (up to `BatchSize`, 25, devices per
question; bigger customers are split, and a question too long for `MaxContextTokens` is split
again), and gets back a table: device, record id or none, confidence, reason. Each device brings
its `BatchCandidatesPerDevice` (5) most similar records. Every row is checked: the record must be
one the script allowed for **that** device (same customer, same location or none, not taken,
serials don't disagree); a bad or missing row counts as "no answer" for that device only, and if
more than half the rows are bad the whole answer is thrown away. If the model gives one record to
two devices, both are held for review. The files are kept as an audit trail in
`C:\ProgramData\NCentralITGlueDeviceSync\ai-batches\<date>-<run>\`: per customer
`<id>-<name>-devices.csv`, `-configs.csv` and `-results.csv` (what the model said and what the
script did), deleted after `LogRetentionDays`.

**Per-device mode (`Mode: "PerDevice"`):** the v0.4 behavior: one question per device with up to
`MaxCandidates` (15) records. Slower, but simpler questions for a small model.

In both modes the candidates are **non-archived** IT Glue configurations from the **same
organization and location** (configurations with no location are included too). The
candidates are pre-filtered by the script: not already linked to another device that is in
N-central, not matched to another device this run, no serial number that disagrees, and ranked by
how alike the names are (and a matching MAC address). If no candidate's name is at least
`MinNameSimilarity` (0.3) alike and no MAC matches, the model isn't asked: it's a new device.

The model must answer strict JSON (Ollama's `format` JSON schema, temperature 0):
`match_id` (a candidate id or empty), `confidence` (0 to 100) and `reason`. The script checks
that the id is one of the candidates it sent, then:

| Answer | What the script does |
|---|---|
| A candidate with confidence >= `AutoLinkConfidence` (90) and `AutoLink` true | Treats it as the match. It's then updated from N-central like any matched device (name, serial, ...), still with every duplicate check, `-Apply`, `MaxChangesPerRun`/`-ChangeLimit`. Without `-Apply` it's only shown in the plan and the link isn't saved. |
| A candidate with confidence >= `ReviewConfidence` (60) | **Held**: not created and not linked. Reported in check 6 with both ids. To accept, add `"<N-central id>": "<IT Glue id>"` to `LocalModel.ApprovedMatches`; to reject, add the same line to `LocalModel.RejectedMatches` (then it's created next run if nothing else matches). |
| No match, or lower confidence | Same as without the model: a new configuration is created (with all the duplicate checks). |
| Ollama down, timeout, or an invalid answer | Same as without the model, and check 6 says the model wasn't available. Three invalid answers in a row or one failed call turns the model off for the rest of the run. |

**Archive suggestions** (`SuggestArchive`, on): for each organization whose devices all matched
this run, every non-archived IT Glue configuration of a type the sync manages (Server, Laptop,
Workstation) that no N-central device is linked to or named like is shown to the model with the
10 most similar N-central device names. "Archive, with confidence >= `ReviewConfidence`" is
reported in check 7. Nothing is archived. To silence one, add its IT Glue id to
`KeepConfigurationIds`.

Limits: at most `MaxCallsPerRun` (100) questions and `MaxMinutesPerRun` (20) minutes of model time
per run. A device that couldn't be asked because of a limit is held until the next run (so a
duplicate can't slip in). Answers are cached in `sync-state.json` for `CacheHours` (14 days) and
reused as long as the question is exactly the same; any change to the device or candidates asks
again. Every question, raw answer and decision is written to `logs\ai-YYYYMMDD.jsonl` (kept
`LogRetentionDays`). The endpoint must be on this computer unless `AllowRemoteEndpoint` is true,
so device and customer names don't leave the machine.

**Speed.** Batch mode asks far fewer questions (one per 25 devices instead of one per device),
though each one takes longer. Each new question takes from a few seconds to a minute, depending on the model and
the PC (the 31b model is several times slower than 12b). The first run with the model on is the
slowest, because nothing is cached yet; later runs only ask about new or changed devices. Per run
the model gets at most `MaxCallsPerRun` (100) new questions, of which at most
`MaxArchiveCallsPerRun` (20) are archive suggestions, and at most `MaxMinutesPerRun` (10) minutes;
the rest wait for the next run. `KeepAlive` (30m) keeps the model loaded between questions;
`ContextTokens` (4096) is enough for these prompts. `Think` is false by default: models like
Gemma 4 otherwise write thousands of words of "thinking" before each answer, which took ~40 s per
question in testing and pushed the JSON answer past the context window. Each answer is capped in
length (`num_predict`), a call that gets no answer within `TimeoutSec` is stopped (hard timeout),
and an answer that isn't valid JSON is asked again once before the devices fall back to normal
matching. `MaxMinutesPerRun` counts time spent waiting for the model only. When the limit is
reached the log says so once; the remaining devices are held until the next run.

Names are compared as they are, without notes in brackets or words like "New"/"old", and by their
leading asset tag (`DR-DT-24 (Brad Sharp) New` is compared as `DR-DT-24` too), so a renamed device
isn't skipped as "no similar names". Every question is logged with its time
(`Local AI (match) ...: 8.4s (model load ..., reading the question ..., writing the answer ...)`).

Model confidence numbers are not well calibrated. Run report-only (or `-DryRun -UseLocalModel`)
for a while and read `sync-preview.json` > `localModel.decisions` before trusting auto-links;
set `AutoLink` to false to hold every suggestion for review. `gemma4:12b` is the default; the 31b
model is slower but usually better at this. Change `Model` and nothing else.

## No duplicates

**Only within one customer.** Every comparison (matching, duplicate checks, the live re-check, the
local AI model) stays inside the device's own IT Glue organization. The same serial number or name
under a different customer is ignored completely: it isn't matched, doesn't block anything and
isn't reported. (Up to v0.6, a serial number found under another customer blocked the device and
was reported.)

The script never creates a duplicate Configuration, and never renames one into a duplicate.
Before **creating** a device it checks every **non-archived** IT Glue configuration:

- **Serial number:** no non-archived configuration in that organization may already have it.
- **Name / hostname:** no non-archived configuration in that organization may already have it.
- Right before the create call, it asks IT Glue again (by serial number and by name, non-archived
  only), in case someone added the device since the run started.

**Archived configurations don't count.** N-central is the source of truth for devices and IT Glue
is only documentation, so an archived IT Glue record is ignored everywhere: it is never matched,
never blocks a create, never triggers a "can't match safely" alert, and is never changed or
unarchived. If a device is in N-central and its only IT Glue record is archived, the script
creates a new Configuration for it. (If the archived record was the one it was linked to before,
the link is dropped and the device is matched or created again like a new one.)

How "archived" is detected (since v0.11, the same as the duplicate-configurations tool), so an
archived record can't slip through if IT Glue ignores one signal: (1) IT Glue is asked for
`filter[archived]=false`; (2) any record that still says it's archived (`archived` true, "true",
1 or "yes", or an `archived-at` date) is dropped; (3) IT Glue's archived list
(`filter[archived]=true`) is read and every id on it is dropped. The log line
`IT Glue configurations: N kept, M archived dropped (...)` shows the counts and which archived
field IT Glue sends. If IT Glue sends no archived field **and** the archived list can't be used,
the run stops (exit 2) instead of guessing. The last-second duplicate check before a create uses
the same rules.

If any check finds something, the device is **not created** and the match is listed in the alert
(check 3), with the existing configuration's id, so a person can fix it. Updates follow the same
rule: a name, hostname or serial number change that would match another configuration is left out.

Duplicates inside N-central are caught too. Two N-central devices with the same serial number,
or the same name in the same customer, are reported; only the one that checked in most recently
is synced.

**Is something else already syncing devices into IT Glue?** Each run logs how many IT Glue
configurations are linked to an RMM or PSA integration (`rmm-integration-type`,
`psa-integration-type`). Zero means nothing else is managing them.

## Safety

- **Report-only by default.** Without `-Apply` nothing in IT Glue changes: the script reads both
  systems, writes the plan to `sync-preview.json`, alerts and saves state.
- `-DryRun` (or `-WhatIf`) also sends no alert and saves no state.
- `-Apply -DeviceId 12345` changes only that N-central device (for a first live test).
- At most `Sync.MaxChangesPerRun` (100) creates/updates per run; the rest go on the next runs.
  `-ChangeLimit 800` raises it for one manual run (the first import).
- At most `Sync.MaxRetiresPerRun` (10) status changes for gone devices; above that **nothing** is
  changed and it's reported. `-RetireLimit N` allows more for one run.
- The only IT Glue writes are `POST /configurations` and `PATCH /configurations/{id}`. Creates are
  not retried after a timeout, so a configuration can't be created twice. No redirects followed.
- The local AI model (optional) only suggests. It never creates, archives or deletes anything,
  its answers are checked, and only a high-confidence match to one of the candidates the script
  sent is used. See "Optional: local AI model".
- N-central is only read (plus the token sign-in). Paging is checked, so a partial read can't make
  devices look "gone".

## Files

| File | What it is |
|---|---|
| `Invoke-NCentralITGlueDeviceSync.ps1` | The sync. |
| `Register-NCentralITGlueDeviceSyncTask.ps1` | Saves secrets encrypted (DPAPI) and registers the scheduled task. |
| `NCentralITGlueDeviceSync.config.example.json` | Example settings. Copy to `NCentralITGlueDeviceSync.config.json`. |

Data folder (default `C:\ProgramData\NCentralITGlueDeviceSync`): `logs\sync-yyyyMMdd.log`,
`logs\ai-yyyyMMdd.jsonl` (local AI model questions, answers and decisions, only when it's on),
`state.json` (alert state), `sync-state.json` (device links, hardware cache, cached AI answers),
`sync-preview.json` (last plan), `current-failures.csv` (attached to alerts),
`ncentral-asset-sample.json` (one raw hardware-details reply, to check field names), `secrets.json`, `sync.lock`.

Timing: every run ends with `Time: ...s in total. N-central ...s (N calls), IT Glue ...s (N calls),
local AI ...s (...), everything else ...s` and a `Time per step:` line, so you can see where a slow
run spent its time. Reading hardware details from N-central (up to `MaxAssetLookupsPerRun`, 300,
one call per device, cached for 24 hours) is usually the slow part of a run without the model.

Exit codes: 0 all matched, 1 devices skipped because of a problem (including local AI suggestions waiting for a person), 2 couldn't run,
3 alert couldn't be sent, 4 IT Glue refused a change or the retire limit was hit.

## Setup

> **Full step-by-step guide for anyone setting this up:** [SETUP-INSTRUCTIONS.md](SETUP-INSTRUCTIONS.md).

Windows PowerShell 5.1 or PowerShell 7+, no modules. Same layout as the health monitor, for
example `C:\LTI\NCentralITGlueDeviceSync`, running as the same service account.

1. **N-central API user.** In N-central create a user with read-only access to all customers
   (a role that can view devices), then Administration > User Management > Users > (user) >
   **API Access** > Generate JSON Web Token. N-central 2023.x or newer has the REST API.
2. **IT Glue API key.** A new key just for this sync (Password Access off). IT Glue keys can't be
   read-only, and this one does write configurations.
3. **Config.** Copy the example to `NCentralITGlueDeviceSync.config.json`; set
   `NCentral.ServerUrl` and the `Smtp` block. Check `DeviceClassMap` type names exist in IT Glue
   (the script stops with the list of valid names if one is wrong).
4. **Secrets** (as the account the task will run as, like the health monitor):
   ```powershell
   runas /user:LTI-DT-AI\svc-itgmonitor powershell.exe
   .\Register-NCentralITGlueDeviceSyncTask.ps1 -SetSecret NCentralApiToken,ITGlueApiKey -SecretScope CurrentUser
   ```
   Or machine environment variables `NCENTRAL_API_TOKEN`, `NCITG_ITGLUE_API_KEY`,
   `NCITG_SMTP_PASSWORD`, `NCITG_WEBHOOK_SECRET`.
5. **Test the email:** `.\Invoke-NCentralITGlueDeviceSync.ps1 -TestNotification`

## First run (in this order)

1. `.\Invoke-NCentralITGlueDeviceSync.ps1 -DryRun` and read the log. Check:
   - `ncentral-asset-sample.json`: does it have `computersystem.serialnumber`, `os.reportedos`,
     `networkadapter[].macaddress`? If the names differ, tell me and I'll adjust the script.
   - the customer and site mismatches (checks 1 and 2). Fix names in N-central or IT Glue.
   - `sync-preview.json`: `creates` and `updates`. If IT Glue already has configurations from
     another integration, they should show as `updates` matched by `serial`, not as `creates`.
   - New devices are "waiting for hardware details" until their serial number is read
     (300 per run). Run `-DryRun` a few times, or raise `MaxAssetLookupsPerRun` once.
2. `.\Invoke-NCentralITGlueDeviceSync.ps1 -Apply -DeviceId <one N-central device id>`, then look
   at that configuration in IT Glue. Repeat with a server and a laptop.
3. Register the task **report-only**: `.\Register-NCentralITGlueDeviceSyncTask.ps1 -TaskUser 'LTI-DT-AI\svc-itgmonitor'`.
   Leave it a day and read the alerts.
4. First import by hand: `.\Invoke-NCentralITGlueDeviceSync.ps1 -Apply -ChangeLimit <creates+updates>`.
5. Register the task with `-Apply`.

## Other integrations

- **N-central has no integration with IT Glue or Halo** (confirmed 2026-11-19), so this script is
  the only thing that puts devices into IT Glue and there's no risk of a second copy from a
  built-in integration. Configurations entered by hand in IT Glue are matched by serial number or
  name, not duplicated.
- **Halo.** The IT Glue health monitor's Halo mirror copies organizations, sites and contacts only.
  Getting these configurations into Halo as assets needs a new step there (IT Glue configurations
  to Halo assets). Not built yet.
