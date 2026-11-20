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

> **Status: v0.3, not yet tested against live N-central or IT Glue.** The N-central field names
> (especially the hardware details from `/api/devices/{id}/assets`) are based on N-able's API
> documentation and need checking on the first dry run. Follow "First run" below.

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
| 3 | Can't match safely | Creating or renaming would make a duplicate (see "No duplicates"); two N-central devices with the same serial or name (the older one is skipped and the newest check-in wins); several IT Glue configurations with the same serial or name; the serial is on a configuration under a **different** organization; the device moved customer in N-central; or IT Glue keeps ignoring an update after `MaxRetries` (3). Nothing is changed for these. |
| 4 | IT Glue refused | A create or update was refused (with IT Glue's error). Retried next run. |
| 5 | Gone from N-central | A device synced before is no longer in N-central. Report only by default; `RetiredDeviceAction: "SetStatus"` sets its status to `RetiredStatus` instead. |

## How a device is matched to an IT Glue configuration

1. The configuration it was linked to before (saved in `sync-state.json`).
2. Otherwise a configuration in the **same organization** with the same **serial number**.
   Placeholder serials like "To Be Filled By O.E.M." are ignored (`IgnoreSerials`).
3. Otherwise one in the same organization with the same **name or hostname**, if the serial
   numbers don't disagree (`Sync.MatchByName`).
4. Otherwise a new configuration is created. A new device waits until its serial number has been
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

## No duplicates

The script never creates a duplicate Configuration, and never renames one into a duplicate.
Before **creating** a device it checks every **non-archived** IT Glue configuration:

- **Serial number:** no non-archived configuration anywhere in IT Glue (any organization) may
  already have it.
- **Name / hostname:** no non-archived configuration in that organization may already have it.
- Right before the create call, it asks IT Glue again (by serial number and by name, non-archived
  only), in case someone added the device since the run started.

**Archived configurations don't count.** N-central is the source of truth for devices and IT Glue
is only documentation, so an archived IT Glue record is ignored everywhere: it is never matched,
never blocks a create, never triggers a "can't match safely" alert, and is never changed or
unarchived. If a device is in N-central and its only IT Glue record is archived, the script
creates a new Configuration for it. (If the archived record was the one it was linked to before,
the link is dropped and the device is matched or created again like a new one.)

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
- N-central is only read (plus the token sign-in). Paging is checked, so a partial read can't make
  devices look "gone".

## Files

| File | What it is |
|---|---|
| `Invoke-NCentralITGlueDeviceSync.ps1` | The sync. |
| `Register-NCentralITGlueDeviceSyncTask.ps1` | Saves secrets encrypted (DPAPI) and registers the scheduled task. |
| `NCentralITGlueDeviceSync.config.example.json` | Example settings. Copy to `NCentralITGlueDeviceSync.config.json`. |

Data folder (default `C:\ProgramData\NCentralITGlueDeviceSync`): `logs\sync-yyyyMMdd.log`,
`state.json` (alert state), `sync-state.json` (device links and hardware cache),
`sync-preview.json` (last plan), `current-failures.csv` (attached to alerts),
`ncentral-asset-sample.json` (one raw hardware-details reply, to check field names), `secrets.json`, `sync.lock`.

Exit codes: 0 all matched, 1 devices skipped because of a problem, 2 couldn't run,
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
