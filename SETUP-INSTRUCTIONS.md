# N-central to IT Glue Device Sync: Setup Instructions

Step-by-step guide to installing and configuring the N-central to IT Glue device sync on the
sync computer. You don't need to know anything about the script beforehand. Do the parts in order
and don't skip the tests.

> **Status:** version 0.10. The script has **not been fully tested against live N-central and
> IT Glue yet.** That is why setup goes through a dry run, then a one-device test, then a
> report-only task, before it is allowed to change anything.

---

## What this script does (in one minute)

- It reads every computer and server from **N-central** and creates or updates a matching
  **Configuration** in **IT Glue**.
- It **never** creates, renames or changes IT Glue organizations or locations. It never deletes
  or archives anything.
- A device is only synced when its **N-central customer name matches an IT Glue organization
  name**, and its **N-central site name matches one of that organization's locations**. Devices
  that don't match are skipped and reported by email.
- It never creates a duplicate within a customer (same serial number or same name in the
  same organization; the same serial or name under a different customer is ignored). Archived
  IT Glue configurations don't count: if a device is in N-central
  and its only IT Glue record is archived, a new one is created. Archived records are never
  changed.
- **It changes nothing unless you add `-Apply`.** Without it, it only reports.

---

## The names used in this guide

| Thing | Value |
|---|---|
| Sync computer | `LTI-DT-AI` (standalone workgroup PC, same one that runs the IT Glue health monitor) |
| Service account the task runs as | `LTI-DT-AI\svc-itgmonitor` (local account, already used by the health monitor) |
| Admin account | your local administrator account on `LTI-DT-AI` (for example `ltiadmin`) |
| Script folder | `C:\LTI\NCentralITGlueDeviceSync` |
| Data folder (logs, state, secrets) | `C:\ProgramData\NCentralITGlueDeviceSync` |
| Scheduled task name | `N-central to IT Glue Device Sync` |
| GitHub repository | https://github.com/LTI865/N-Central_DeviceToHaloSync |

If any of these differ on your setup, change them in the commands below.

### Two kinds of PowerShell window

You will use **two different PowerShell windows**. Mixing them up is the most common mistake.

| Window | How to open it | Use it for |
|---|---|---|
| **Admin window** | Start menu > type `PowerShell` > right-click > **Run as administrator** | Copying files, folder permissions, editing the config, registering or removing the task, deleting secrets |
| **Service-account window** | From the admin window, run the `runas` command in Part 5 | Saving secrets, the email test, dry runs, manual runs |

In any window, type `whoami` to see which account it is running as.

---

## Part 1. Prerequisites

Check each of these before you start.

1. **Windows PowerShell 5.1** (built into Windows 10/11 and Server 2016+) or PowerShell 7. No
   extra modules are needed.
2. **The service account exists:** `LTI-DT-AI\svc-itgmonitor`, a member of the local **Users**
   group, with the **Log on as a batch job** right. (It already has this because the IT Glue
   health monitor uses it.) You need its password.
3. **N-central 2023.x or newer** (that's when the REST API was added). You need an N-central
   admin login to create a user.
4. **IT Glue administrator** login (to create an API key).
5. **Customer and site names line up.** Every N-central customer you want synced must have an
   IT Glue organization with the same name, and every N-central site must have an IT Glue
   location with the same name in that organization. (Capital letters and extra spaces don't
   matter.) The dry run in Part 7 lists every one that doesn't match.
6. **IT Glue configuration types** named `Server`, `Laptop` and `Workstation` exist (Account >
   Customize Sidebar / Configuration Types). If yours are named differently, you'll change
   `DeviceClassMap` in Part 4.
7. **SMTP details** for alert emails (server, port, from address, who gets alerts, and a
   username and password if the server needs one). You can skip email for now; see Part 4.

---

## Part 2. Create the N-central API user and token

The script only **reads** from N-central, so give it a read-only user.

1. Sign in to N-central as an administrator.
2. Go to **Administration > User Management > Roles** and make sure there's a role that can
   **view devices** but not change anything (a read-only role). Create one if needed.
3. Go to **Administration > User Management > Users > Add**.
   - Name it something obvious, for example `api-itglue-device-sync`.
   - Give it the read-only role and access to **all customers** (so it can see every device).
   - Save.
4. Open the new user, go to the **API Access** tab and click **Generate JSON Web Token**.
5. **Copy the token right away** and keep it somewhere safe for a few minutes (you'll paste it
   in Part 5). It's a long string of letters, numbers and dots.
   - If you generate a new token later, the old one stops working, and you'll need to save
     the new one again (Part 5, step 5).

## Part 3. Create the IT Glue API key

Use a **new key just for this sync**, not the health monitor's key, so it can be turned off on
its own.

1. Sign in to IT Glue as an administrator.
2. Go to **Account > Settings > API Keys** and click **+ Generate API Key**.
3. Name it `N-central device sync`.
4. **Leave "Password Access" OFF (unticked).** The sync never needs passwords.
5. Click **Generate** and **copy the key right away**. IT Glue only shows it once.

Note: IT Glue keys can't be made read-only. This one does need to write, because it creates and
updates configurations.

---

## Part 4. Copy the files and edit the config

Do all of Part 4 in the **admin window**.

### 4.1 Put the files in the script folder

1. Get the files from https://github.com/LTI865/N-Central_DeviceToHaloSync (Code > Download ZIP,
   or `git clone`). You need these three:
   - `Invoke-NCentralITGlueDeviceSync.ps1`
   - `Register-NCentralITGlueDeviceSyncTask.ps1`
   - `NCentralITGlueDeviceSync.config.example.json`
2. Create the script folder and copy the files into it. Change the source path to where you
   downloaded them:
   ```powershell
   New-Item -ItemType Directory -Path 'C:\LTI\NCentralITGlueDeviceSync' -Force
   Copy-Item -Path 'C:\Users\ltiadmin\Downloads\N-Central_DeviceToHaloSync-main\*' -Destination 'C:\LTI\NCentralITGlueDeviceSync' -Recurse -Force
   ```
3. Remove the "downloaded from the internet" flag so Windows lets the scripts run:
   ```powershell
   Get-ChildItem 'C:\LTI\NCentralITGlueDeviceSync' -Recurse | Unblock-File
   ```
4. Lock the script folder so the service account can run the scripts but not change them:
   ```powershell
   icacls 'C:\LTI\NCentralITGlueDeviceSync' /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' 'LTI-DT-AI\svc-itgmonitor:(OI)(CI)RX'
   ```

### 4.2 Create the data folder and let the service account write to it

The service account writes logs, state and its secrets here.
```powershell
New-Item -ItemType Directory -Path 'C:\ProgramData\NCentralITGlueDeviceSync' -Force
icacls 'C:\ProgramData\NCentralITGlueDeviceSync' /grant 'LTI-DT-AI\svc-itgmonitor:(OI)(CI)M'
```

### 4.3 Create the config file

1. Make your own copy of the example:
   ```powershell
   cd 'C:\LTI\NCentralITGlueDeviceSync'
   Copy-Item .\NCentralITGlueDeviceSync.config.example.json .\NCentralITGlueDeviceSync.config.json
   notepad .\NCentralITGlueDeviceSync.config.json
   ```
2. Change these settings, then save. **Never put a token, API key or password in this file.**
   Those go in the encrypted secrets file in Part 5.

   **N-central address** (just the https address, nothing after it):
   ```json
   "NCentral": {
     "ServerUrl": "https://your-ncentral-server.example.com",
   ```
   Right: `https://ncentral.mycompany.com`. Wrong: `https://ncentral.mycompany.com/` with a path
   after it, or `http://...`.

   **Email alerts** (the `Smtp` block):
   ```json
   "Smtp": {
     "Server": "smtp.office365.com",
     "Port": 587,
     "UseSsl": true,
     "From": "device-sync@yourdomain.com",
     "To": ["helpdesk-leads@yourdomain.com"],
     "Username": "device-sync@yourdomain.com",
     "SubjectPrefix": "[N-central > IT Glue]"
   },
   ```
   - Leave `"Username": ""` if your SMTP server doesn't need a sign-in. If you fill in a
     username, you also save `SmtpPassword` in Part 5.
   - **No email for now?** Set `"NotificationMethods": []`. The script will still log
     everything; it just won't send mail. (This is how the health monitor is set up today.)

   **Device types** (`DeviceClassMap`): the N-central device class on the left (`Match`, not
   case-sensitive) goes to the IT Glue configuration type on the right. Only change the right
   side if your IT Glue type names are different:
   ```json
   "DeviceClassMap": [
     { "Match": "server", "ConfigurationType": "Server" },
     { "Match": "laptop", "ConfigurationType": "Laptop" },
     { "Match": "workstation|desktop", "ConfigurationType": "Workstation" }
   ],
   ```
   If a name is wrong, the first run stops and lists the type names IT Glue actually has, so
   you can copy the right one. Devices of any other class (printers, switches, probes) are
   skipped.

   **Customer name map** (`CustomerNameMap`): leave it empty unless a customer's name **can't**
   be made the same in both systems. Then add one line per customer:
   ```json
   "CustomerNameMap": {
     "Acme Corp (N-central name)": "Acme Corporation (IT Glue name)"
   },
   ```
   Fixing the name in N-central or IT Glue is better than mapping it.

   **Leave a customer out on purpose** (for example your own internal one): add its name to
   `"ExcludeCustomerNames": ["Our Internal Customer"]` in the `NCentral` block.

3. Check the file is valid: if you get a red error here, there's a typo (usually a missing comma
   or quote):
   ```powershell
   Get-Content .\NCentralITGlueDeviceSync.config.json -Raw | ConvertFrom-Json | Out-Null; 'Config OK'
   ```

---

## Part 5. Save the secrets as the service account (runas)

### Why this matters, read before you start

The token and API key are saved **encrypted** in
`C:\ProgramData\NCentralITGlueDeviceSync\secrets.json`, using Windows encryption tied to a
single user account (`-SecretScope CurrentUser`).

- **Only the account that saves the secrets can decrypt them.** Not the admin, not SYSTEM, not
  anyone else.
- The scheduled task runs as `LTI-DT-AI\svc-itgmonitor`, so **the secrets must be saved by
  `svc-itgmonitor`**, from a window opened with `runas`.
- **If you saved them from your admin window by mistake**, the task can't read them (the log
  says `Couldn't decrypt secret` or `Key not valid`). Saving them again as the service account
  on top of the old file won't work either, because the service account can't open a file the
  admin created. **You have to delete `secrets.json` and start Part 5 again.** See Part 11.1.

### Steps

1. In the **admin window**, open a PowerShell window running as the service account:
   ```powershell
   runas /user:LTI-DT-AI\svc-itgmonitor "powershell.exe -NoProfile -ExecutionPolicy Bypass"
   ```
   Type the service account's password when asked (nothing shows as you type). A **new**
   PowerShell window opens. Do steps 2 to 6 in that new window.
2. Check that it's the right account. This must print `lti-dt-ai\svc-itgmonitor`:
   ```powershell
   whoami
   ```
3. Go to the script folder:
   ```powershell
   cd 'C:\LTI\NCentralITGlueDeviceSync'
   ```
4. Save the N-central token and the IT Glue key:
   ```powershell
   .\Register-NCentralITGlueDeviceSyncTask.ps1 -SetSecret NCentralApiToken,ITGlueApiKey -SecretScope CurrentUser
   ```
   - At `Enter NCentralApiToken`, paste the N-central token from Part 2 and press Enter.
   - At `Enter ITGlueApiKey`, paste the IT Glue key from Part 3 and press Enter.
   - Input is hidden, so you won't see it. Right-click pastes in a PowerShell window.
   - You should see `Saved NCentralApiToken.`, `Saved ITGlueApiKey.` and a yellow line saying
     only `LTI-DT-AI\svc-itgmonitor` can decrypt these secrets. That's expected.
5. **Only if** you set an SMTP `Username` in Part 4, save its password too:
   ```powershell
   .\Register-NCentralITGlueDeviceSyncTask.ps1 -SetSecret SmtpPassword -SecretScope CurrentUser
   ```
   You can save one secret at a time later the same way (for example after generating a new
   N-central token). It replaces only that secret and keeps the others.
6. **Keep this service-account window open.** You'll use it for Parts 6 to 8.
7. Delete the token and key from wherever you pasted them temporarily (Notepad, clipboard
   history, and so on).

---

## Part 6. Test the email

In the **service-account window**:
```powershell
.\Invoke-NCentralITGlueDeviceSync.ps1 -TestNotification
```
- A test message should arrive at every address in `Smtp.To` within a minute or two.
- If it says `Notification via Smtp FAILED`, read the reason after it (wrong server or port,
  wrong password, sender not allowed). Fix the config or save `SmtpPassword` again, and repeat.
- If `NotificationMethods` is `[]`, it says nothing was sent. That's fine.

---

## Part 7. Dry run and what to check

A dry run reads N-central and IT Glue and shows what it **would** do. It changes nothing, sends
no email and saves no state.

1. In the **service-account window**:
   ```powershell
   .\Invoke-NCentralITGlueDeviceSync.ps1 -DryRun
   ```
   It can take several minutes the first time (it reads hardware details for up to 300 devices
   per run).
2. Read the output (also saved in `C:\ProgramData\NCentralITGlueDeviceSync\logs\sync-YYYYMMDD.log`).
   Near the end is a line like:
   `Plan: 40 to create, 12 to update, 0 already match, 260 new devices waiting for hardware details, 3 conflicts, 0 removed from N-central.`
3. Check these things, in this order:

   **a. It signed in to both systems.** If it stopped with an error, see Part 12.

   **b. The hardware details have the right field names.** Open
   `C:\ProgramData\NCentralITGlueDeviceSync\ncentral-asset-sample.json` in Notepad. It's one raw
   reply from N-central. Look for a serial number under `computersystem` > `serialnumber`, the
   OS under `os` > `reportedos`, and MAC addresses under `networkadapter` > `macaddress`. If
   those names are different or missing, **stop and report it** so the script can be adjusted.
   This is the part of the script that's least certain.

   **c. Customer and site mismatches** (checks 1 and 2 in the log). Each one is an N-central
   customer or site with no matching IT Glue organization or location. Fix the name in N-central
   or IT Glue (or add a `CustomerNameMap` line), then run the dry run again. These devices won't
   sync until they match; everything else still will.

   **d. The plan.** Open `C:\ProgramData\NCentralITGlueDeviceSync\sync-preview.json`. It has
   `creates` (new configurations) and `updates` (existing ones that will change). Devices
   already typed into IT Glue by hand should show under `updates` (matched by serial or name),
   **not** under `creates`. If you see devices you know are already in IT Glue under `creates`,
   stop and investigate before going further.

   **e. Conflicts** (check 3). Things like the same serial in two IT Glue organizations, or two
   N-central devices with the same name. The script won't touch these. Fix them by hand when you
   can.

   **f. "Waiting for hardware details".** A new device isn't created until its serial number
   has been read, so it can't be created twice. Run `-DryRun` a few more times until this
   number drops to near zero. (A dry run doesn't save the cache, so after the first report-only
   run in Part 9 this clears up on its own.)

---

## Part 8. Test on one device with -Apply

Now let it make a real change, but to **one device only**.

1. Pick a device. Its N-central device ID is the `ncId` value in `sync-preview.json`, or the
   number in the device's page address in N-central. Start with a device listed under
   `creates` or `updates`.
2. In the **service-account window**:
   ```powershell
   .\Invoke-NCentralITGlueDeviceSync.ps1 -Apply -DeviceId 123456789
   ```
   (Replace `123456789` with the real ID.)
3. Open that organization in IT Glue and check the configuration: name, hostname, serial
   number, type, location, OS notes, manufacturer and model.
4. Run the **same command again**. It should say the device already matches and change nothing.
   That proves it won't create a duplicate.
5. Repeat steps 2 to 4 with **one server and one laptop** so each device type is tested.

---

## Part 9. Register the task in report-only mode

The task runs every 60 minutes. In report-only mode it reads, plans, saves state and sends
alerts, but **changes nothing in IT Glue**.

1. **Close** the service-account window and use the **admin window**:
   ```powershell
   cd 'C:\LTI\NCentralITGlueDeviceSync'
   .\Register-NCentralITGlueDeviceSyncTask.ps1 -TaskUser 'LTI-DT-AI\svc-itgmonitor'
   ```
2. When the password box appears, type the **service account's** password (the user name is
   already filled in).
3. It prints `Scheduled task ... registered (REPORT ONLY)` and the time of the first run (in
   2 minutes).
4. After that, check the run finished:
   ```powershell
   Get-ScheduledTaskInfo -TaskName 'N-central to IT Glue Device Sync' | Select-Object LastRunTime, LastTaskResult
   ```
   `LastTaskResult` is the exit code (see Part 12). `267009` means it's still running.
5. **Leave it for a day.** Read the alert emails and the log. Fix any names it reports.

---

## Part 10. First import, then turn on -Apply

### 10.1 First import by hand

Normally the sync makes at most 100 changes per run. For the first big import, run it once by
hand with a higher limit.

1. Open a **service-account window** again (Part 5, steps 1 to 3).
2. Run a dry run and note the numbers `to create` and `to update`:
   ```powershell
   .\Invoke-NCentralITGlueDeviceSync.ps1 -DryRun
   ```
3. Run the import with `-ChangeLimit` set to **creates + updates** (for example 40 + 12 = 52):
   ```powershell
   .\Invoke-NCentralITGlueDeviceSync.ps1 -Apply -ChangeLimit 52
   ```
4. Spot-check a few customers in IT Glue. Look for anything duplicated or in the wrong place.

### 10.2 Register the task with -Apply

In the **admin window**:
```powershell
cd 'C:\LTI\NCentralITGlueDeviceSync'
.\Register-NCentralITGlueDeviceSyncTask.ps1 -TaskUser 'LTI-DT-AI\svc-itgmonitor' -Apply
```
Type the service account's password again. It prints
`registered (APPLY (creates/updates IT Glue configurations))`. This replaces the report-only
task; there's still only one task.

To go back to report-only at any time, run the same command **without** `-Apply`.

Setup is done. Part 10.3 is optional.

### 10.3 Optional: turn on the local AI model (Ollama)

This lets a model running in Ollama on this PC look at devices that the serial-number and name
checks couldn't match (for example `JSMITH-LT` in N-central and `John Smith Laptop` in IT Glue),
and suggest IT Glue records that look retired. The script still makes every decision; the model
never creates, archives or deletes anything. How it works and what each answer does: README,
"Optional: local AI model". **This mode hasn't been tested against Ollama yet**, so go through
the steps in order.

**1. Make sure Ollama runs even when nobody is logged in.** The scheduled task runs as
`svc-itgmonitor`, often with nobody signed in. The Ollama desktop app only runs while the person
who installed it is logged in, so the task would find it down (the sync then carries on without
the model and the alert says so). Either keep that user logged in, or run `ollama serve` from its
own scheduled task "At startup" (as the account that pulled the models, "Run whether user is
logged on or not"). Ollama listens on `127.0.0.1:11434` by default, which every account on this
PC can reach; nothing has to be opened in the firewall. Don't set `OLLAMA_HOST=0.0.0.0`.

**2. Pull and check the model** (in a normal window as the account that runs Ollama):
```powershell
ollama pull gemma4:12b
ollama list
ollama run gemma4:12b "Say OK"
```
`ollama list` must show the exact name you'll put in the config. To try the larger one later:
`ollama pull gemma4:31b` (slower, usually better at this).

**3. Check that the service account can reach Ollama.** In a **service-account window**
(Part 5, steps 1 to 3):
```powershell
whoami
(Invoke-RestMethod http://localhost:11434/api/tags).models.name
```
It must print `lti-dt-ai\svc-itgmonitor` and list `gemma4:12b`. If it can't connect, Ollama
isn't running (step 1).

**4. Dry run with the model**, still in the service-account window:
```powershell
cd 'C:\LTI\NCentralITGlueDeviceSync'
.\Invoke-NCentralITGlueDeviceSync.ps1 -DryRun -UseLocalModel
```
Look for `Local AI model 'gemma4:12b' is available` near the top and a `Local AI: N asked ...`
summary near the end. The first question can take a minute while the model loads. Then read:
- `C:\ProgramData\NCentralITGlueDeviceSync\sync-preview.json` > `localModel.decisions`: one
  line per device or record, with the action (`link`, `review`, `none`, `suggest-archive`,
  `keep`), confidence and reason.
- `logs\ai-YYYYMMDD.jsonl`: the exact question and raw answer for each.
- `ai-batches\<date>-<run>\`: per customer, the devices and IT Glue records that were sent (as
  CSV) and `-results.csv` with the model's answer and what the script did with each device.
  (Batch mode, the default. Set `"Mode": "PerDevice"` for one question per device instead.)

If a `link` decision is wrong, the model is too confident for automatic links: set
`"AutoLink": false` (everything is held for you to check) or raise `AutoLinkConfidence`. If it
keeps timing out, raise `TimeoutSec` or use the smaller model.

**5. Turn it on for the task.** In the **admin window**, edit the config and set:
```json
"LocalModel": { "Enabled": true, "Model": "gemma4:12b" }
```
(add only the settings you change; the rest use the defaults in the example config). The task
doesn't need to be registered again; the next run uses it.

**6. Handling the alerts.**
- *Check 6, possible match:* the device is **not created** until you decide. Open both records.
  Same device: add the line from the alert to `"ApprovedMatches"`, for example
  `"ApprovedMatches": { "123456789": "4567890" }`. Different device: add the same line to
  `"RejectedMatches"` instead. The next run links it or creates it.
- *Check 7, consider archiving:* archive it in IT Glue yourself if it's retired, or add its id to
  `"KeepConfigurationIds": [ "4567890" ]` to stop the suggestion.
- *Check 6, "Local AI model not available":* Ollama was down or the model is missing; devices
  were matched the normal way that run.

To turn the model off again, set `"Enabled": false`.

---

## Part 11. Removing or redoing things

### 11.1 Delete the secrets and save them again

Do this if the secrets were saved by the wrong account (for example the admin), or a token was
regenerated and you'd rather start clean.

1. In the **admin window**, check who created the file (the owner should be
   `LTI-DT-AI\svc-itgmonitor`):
   ```powershell
   (Get-Acl 'C:\ProgramData\NCentralITGlueDeviceSync\secrets.json').Owner
   ```
2. Delete it:
   ```powershell
   Remove-Item 'C:\ProgramData\NCentralITGlueDeviceSync\secrets.json' -Force
   ```
3. Do **all of Part 5 again**, from the `runas` step. Save every secret again
   (`NCentralApiToken`, `ITGlueApiKey`, and `SmtpPassword` if used), because the file now has
   none.
4. In the service-account window, run `.\Invoke-NCentralITGlueDeviceSync.ps1 -DryRun` to prove
   the secrets work.

You don't need to re-register the task after this; it reads the new file on its next run.

### 11.2 Replace just one secret

If the file was saved by the service account and only one value changed (for example a new
N-central token), open a service-account window (Part 5, steps 1 to 3) and save only that one:
```powershell
.\Register-NCentralITGlueDeviceSyncTask.ps1 -SetSecret NCentralApiToken -SecretScope CurrentUser
```

### 11.3 Stop or remove the scheduled task

- **Pause it** (admin window):
  ```powershell
  Disable-ScheduledTask -TaskName 'N-central to IT Glue Device Sync'
  ```
  `Enable-ScheduledTask` turns it back on.
- **Remove it** (admin window):
  ```powershell
  cd 'C:\LTI\NCentralITGlueDeviceSync'
  .\Register-NCentralITGlueDeviceSyncTask.ps1 -Unregister
  ```
  This only removes the task. Logs, state and secrets in the data folder are kept.
- **Run it now** instead of waiting:
  ```powershell
  Start-ScheduledTask -TaskName 'N-central to IT Glue Device Sync'
  ```

### 11.4 Update to a new version of the script

1. Download the new files from GitHub.
2. In the **admin window**, copy them over the old ones in `C:\LTI\NCentralITGlueDeviceSync`
   (don't overwrite your `NCentralITGlueDeviceSync.config.json`), then run
   `Get-ChildItem 'C:\LTI\NCentralITGlueDeviceSync' -Recurse | Unblock-File`.
3. The first line of the next log shows the version that ran.

### 11.5 Remove everything

1. Remove the task (11.3).
2. Delete `C:\LTI\NCentralITGlueDeviceSync` and `C:\ProgramData\NCentralITGlueDeviceSync`.
3. Delete the IT Glue API key (Account > Settings > API Keys) and the N-central API user.

The configurations already created in IT Glue stay. The script never deletes them.

---

## Part 12. Troubleshooting

### Exit codes

Shown at the end of every run (`Finished with exit code N`) and as `LastTaskResult` for the task.

| Code | Means | What to do |
|---|---|---|
| 0 | Everything matched (and with `-Apply`, every change was made) | Nothing |
| 1 | Some devices were skipped because of a problem (name mismatch, conflict, or a local AI suggestion waiting for you). Alert sent | Read the alert or log, fix the names or conflicts, or answer the AI suggestion (Part 10.3, step 6) |
| 2 | The sync couldn't run (config, token, key, N-central or IT Glue unreachable) | Read the red error in the log; see the table below |
| 3 | An alert email couldn't be sent (it's retried next run) | Run `-TestNotification` and fix SMTP |
| 4 | IT Glue refused a change, or too many devices disappeared from N-central at once | Read check 4 or 5 in the log |
| 267009 | (Task only) still running | Wait |

### Common errors

| You see | Cause | Fix |
|---|---|---|
| `Couldn't decrypt secret ...` or `Key not valid for use in specified state` | The secrets were saved by a different account than the one running now (usually saved as admin, run as the service account, or the other way around) | Run tests in a **service-account window**. If the secrets were saved as admin, follow Part 11.1 |
| `Access to the path ...\secrets.json is denied` while saving secrets | An old `secrets.json` made by another account is in the way | Part 11.1 (delete it in the admin window, save again as the service account) |
| `No N-central API token found` / `No IT Glue API key found` | That secret was never saved, or `secrets.json` was deleted | Part 5, step 4 |
| `N-central refused the API token (HTTP 401/403)` | Token expired or regenerated, or the user has no API access | Generate a new token (Part 2) and save it (Part 11.2) |
| `NCentral.ServerUrl must be just the https address ...` | Wrong `ServerUrl` | Use only `https://your-server` with nothing after it |
| `IT Glue has no configuration type named 'X'` | `DeviceClassMap` has a type name IT Glue doesn't have | Copy the right name from the list in the error into the config |
| `Config file ... is not valid JSON` | Typo in the config | Run the check in Part 4.3, step 3 |
| `Can't create '...\logs'` | The service account can't write to the data folder | Part 4.2 (`icacls ... /grant ...:(OI)(CI)M`) |
| `Run this from an elevated PowerShell` | Registering the task from a normal window | Use the admin window |
| `Another run is still in progress: ...sync.lock is open (PID ..., account, started ...)` | The task and a manual run overlapped | Wait for the other run to finish; it's harmless. The message names the process that holds it |
| `Lock file ...sync.lock can't be opened by ...: Access to the path ... is denied` | The lock file was made by a different account (for example a run in the admin window, then one as the service account). Not another run | The script removes it and carries on. If it says it couldn't remove it, delete `C:\ProgramData\NCentralITGlueDeviceSync\sync.lock` in the admin window and check Part 4.2. Up to v0.4 this showed as "Another run is still in progress" by mistake |
| `running scripts is disabled on this system` | Execution policy | Open the window with `-ExecutionPolicy Bypass` (as in Part 5) and run `Unblock-File` (Part 4.1) |
| `runas` says `Logon failure` | Wrong password, or the account is disabled | Check the account in Computer Management > Local Users and Groups |
| Task never runs, `LastTaskResult` 2147943785 | The service account lacks **Log on as a batch job** | Add it in `secpol.msc` > Local Policies > User Rights Assignment |
| Task fails after the service account's password was changed | The task stores the password | Re-register the task (Part 9 or 10.2) with the new password |
| `Ollama isn't answering at http://localhost:11434` | Ollama isn't running for the task (nobody logged in), or the app was closed | Part 10.3, step 1 |
| `Ollama ... doesn't have the model 'X'` | The model name in the config doesn't match `ollama list` | `ollama pull X`, or copy the exact name from `ollama list` |
| `LocalModel.Endpoint ... is not on this computer` | Endpoint points at another machine | Use `http://localhost:11434`, or set `AllowRemoteEndpoint` if that's really intended |
| A run is slow | Read the `Time:` and `Time per step:` lines at the end of the log | Compare with a run without the model: `.\Invoke-NCentralITGlueDeviceSync.ps1 -DryRun` (no `-UseLocalModel`, and `LocalModel.Enabled` false). If the local AI takes the time: the first run is the slowest (later runs reuse answers); lower `MaxCallsPerRun` / `MaxMinutesPerRun`, set `SuggestArchive` false, use the 12b model, or set `Think` false if the log says the model is thinking. If N-central takes the time: that's the hardware details for new devices, and it drops once they're cached |
| `Ollama stopped answering during the run (... timed out)` | The model is slow or still loading | Raise `LocalModel.TimeoutSec`, or use the smaller model |
| Devices listed under `creates` that already exist in IT Glue | Serial or name differs between the two systems | Don't apply. Fix the record by hand or report it |
| `waiting for hardware details` doesn't go down | Only 300 devices are read per run | Let the report-only task run a few times, or raise `NCentral.MaxAssetLookupsPerRun` for one run |

### Where to look

All in `C:\ProgramData\NCentralITGlueDeviceSync`:

| File | What's in it |
|---|---|
| `logs\sync-YYYYMMDD.log` | Everything each run did (kept 30 days) |
| `sync-preview.json` | The last plan: `creates`, `updates`, `retire` |
| `current-failures.csv` | The current problems (also attached to alert emails) |
| `ncentral-asset-sample.json` | One raw hardware reply from N-central, to check field names |
| `sync-state.json` | Which N-central device is linked to which IT Glue configuration (and cached local AI answers) |
| `logs\ai-YYYYMMDD.jsonl` | Local AI model only: every question, raw answer and decision (kept 30 days) |
| `state.json` | Alert history (so the same alert isn't sent every run) |
| `secrets.json` | Encrypted secrets. Not readable by people; only the saving account can decrypt them |

### Quick reference: which window for what

| Task | Window |
|---|---|
| Copy files, `icacls`, edit config | Admin |
| `-SetSecret ... -SecretScope CurrentUser` | **Service account (runas)** |
| `-TestNotification`, `-DryRun`, `-Apply -DeviceId`, `-Apply -ChangeLimit` | **Service account (runas)** |
| `-DryRun -UseLocalModel`, checking Ollama with `Invoke-RestMethod` | **Service account (runas)** |
| `ollama pull`, `ollama list` | The account that runs Ollama |
| Register task, `-Unregister`, delete `secrets.json` | Admin |
