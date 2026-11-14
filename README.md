# Memcat

DFIR Memory Acquisition Pipeline
Wazuh Active Response • Windows endpoint • WinPmem • Encryption • Tailscale • SFTP

Implementation record and deployment reference

Scope and evidence note: This guide records the configuration and behavior established during the project.  Do not treat example addresses, usernames, paths, or permission settings as proof of the live configuration. Current Limitation it only tested on windows 10.

**Contents
⦁	Overview and architecture
⦁	Part 1 — Build and install the acquisition pipeline
⦁	Part 2 — Ubuntu Wazuh server, Tailscale and SFTP collection
⦁	Recommended permissions and hardening
⦁	End-to-end validation and troubleshooting
⦁	Operational limitations and handover checklist**

**Overview and architecture**

The solution provides an analyst-triggered memory acquisition workflow from a custom Wazuh Dashboard plugin. The plugin sends an Active Response request through the Wazuh API. The Wazuh agent executes a CMD wrapper, which starts a PowerShell handler. The handler reads the Wazuh JSON message from standard input, validates the case metadata and analyst public key, and launches the Go acquisition executable.
The Go executable embeds/uses the signed WinPmem executable for physical memory acquisition, calculates a SHA-256 hash of the raw image, compresses/encrypts the evidence using the supplied X25519 public key and AES-256-GCM, writes a manifest, and attempts SFTP upload. If upload fails, the tool retains the encrypted evidence locally.

**Component	Role	Known project detail**

Wazuh Manager/API	Receives the Dashboard request and dispatches Active Response.	Ubuntu server; API endpoint configured as https://localhost:55000 on the Dashboard host.

Wazuh Dashboard plugin	Analyst-facing acquisition console and backend API routes.	Plugin ID: dfAcquisitionConsole; Dashboard/OpenSearch Dashboards 2.19.6.

Windows Wazuh agent	Receives Active Response and launches the handler.	Agent ID 001; Windows 10 Pro N; Wazuh agent v4.14.9.

PowerShell/CMD handler	Reads JSON, extracts arguments, validates input, invokes capture executable and logs execution.	Files in C:\Program Files (x86)\ossec-agent\active-response\bin.

Go acquisition executable	WinPmem acquisition, hashing, encryption, manifest and SFTP upload.
SFTP server destination	Receives encrypted image and manifest.


**PART 1 — Build and install the acquisition pipeline**

**1.1 Prerequisites and version context**

Wazuh Manager/API	Wazuh v4.14.10 was observed on the Ubuntu manager.
Windows agent	Wazuh v4.14.9; Windows 10 Pro N, build 19045.6466.
Dashboard	OpenSearch Dashboards 2.19.6.
Custom plugin	dfAcquisitionConsole.
Plugin source	~/wazuh-dashboard-build/plugins/df-wazuh-acquisition-plugin.
Plugin install location	/usr/share/wazuh-dashboard/plugins/dfAcquisitionConsole.

**1.2 Installation the custom Dashboard plugin**

Run as a user with sudo rights:
sudo /usr/share/wazuh-dashboard/bin/opensearch-dashboards-plugin install \
  file:///home/wazuh/wazuh-dashboard-build/plugins/df-wazuh-acquisition-plugin/build/dfAcquisitionConsole-2.19.6.zip \
  --allow-root
 
sudo systemctl restart wazuh-dashboard
sleep 25
 
**1.3 Wazuh API environment variables and TLS**

The plugin backend authenticates to the Wazuh API using a username/password and a token. The API client source used DF_WAZUH_API_URL with a default of https://127.0.0.1:55000, plus DF_WAZUH_API_USERNAME and DF_WAZUH_API_PASSWORD. The token was cached for ten minutes and refreshed once after HTTP 401.
The Dashboard systemd override used an environment file and explicitly configured the API URL and CA bundle:

/etc/systemd/system/wazuh-dashboard.service.d/override.conf

[Service]
EnvironmentFile=/etc/wazuh-dashboard/df-acquisition.env
Environment="DF_WAZUH_API_URL=https://localhost:55000"
Environment="NODE_EXTRA_CA_CERTS=/etc/wazuh-dashboard/certs/wazuh-api-selfsigned.pem"
The environment file contains credentials. Use the real Wazuh API username and password; do not put secrets in plugin source, browser JavaScript, source control, screenshots, or logs.

/etc/wazuh-dashboard/df-acquisition.env

DF_WAZUH_API_USERNAME=<dedicated-api-user>
DF_WAZUH_API_PASSWORD=<strong-secret>

After editing systemd or environment configuration:
sudo systemctl daemon-reload
sudo systemctl restart wazuh-dashboard

The Node process reads NODE_EXTRA_CA_CERTS at process startup, so restart is required after changing it. The CA file must actually validate the Wazuh API certificate. In this deployment, an existing root-ca.pem did not validate the API certificate; the API certificate was self-signed with subject/issuer CN=wazuh.com, and a dedicated certificate file was configured. Verify the certificate chain rather than disabling TLS verification.
**1.4 Wazuh API client and Active Response route**

The plugin API client calls the Wazuh security authentication endpoint, then sends the Active Response request using HTTP PUT. The relevant endpoint shape tested was:
PUT /active-response?agents_list=001
Content-Type: application/json
 
{
  "command": "!df-memory-capture.cmd",
  "arguments": [
    "case_id=DF-ARG-TEST-001",
    "analyst_id=df.test",
    "pubkey=<64-hex-character-X25519-public-key>"
  ]
}
The command must match the registered Wazuh command name. A request using an incorrect command name returned Wazuh error 1652.

**1.5 Register the command on the Wazuh Manager**

On the Ubuntu Wazuh Manager, edit /var/ossec/etc/ossec.conf and register the command:

<command>
  <name>df-memory-capture</name>
  <executable>df-memory-capture.cmd</executable>
  <timeout_allowed>no</timeout_allowed>
</command>

The executable name must correspond to the wrapper deployed on the Windows agent. The command is invoked by the API as !df-memory-capture.cmd in the  configuration.

The Windows endpoint's Active Response configuration:

<active-response>
  <disabled>no</disabled>
  <ca_store>wpk_root.pem</ca_store>
  <ca_verification>yes</ca_verification>
</active-response>

This enables Active Response and retains certificate verification.

**1.6 Deploy the Windows endpoint files**

The following files were deployed under the Windows agent's Active Response binary directory:
C:\Program Files (x86)\ossec-agent\active-response\bin\
    df-memory-capture.cmd
    df-memory-capture.ps1
The CMD wrapper starts Windows PowerShell without loading the profile, uses non-interactive mode, bypasses the local execution-policy prompt for this signed/deployed handler, and propagates the PowerShell exit code:
Use the deployed script and wrapper names consistently with the manager's command registration.


**1.7 Set the acquisition output directory**

The Go executable's --help output confirmed --output is the acquisition output directory and defaults to the current working directory (.). Without this flag, the output files were written under the Wazuh agent directory because that was the current working directory for the Active Response process.
The observed output layout was C:\DF\Acquisitions\<case-id>\ with the encrypted .fmem evidence file and its JSON manifest. The raw memory image was staged during acquisition and the program reported removal of its staging directory after encryption.

**1.8 Acquisition executable and WinPmem**

The Go acquisition executable memory_capture_go_winpmem.exe. Its help output listed --ticket, --analyst, --winpmem (notool build only), --output, --case-ref, --pubkey, --keygen, --no-cleanup, --verbose, --decrypt and --output-file.

The embedded WinPmem binary was obtained from the Velocidex release URL supplied during the project:
**https://github.com/Velocidex/WinPmem/releases/download/v4.0.rc1/go-winpmem_amd64_1.0-rc2_signed.exe
The project identified this as WinPmem release v4.0.rc1 and the binary go-winpmem_amd64_1.0-rc2_signed.exe. The upstream project identifies its source and signed binaries as Apache License 2.0. Include the applicable upstream LICENSE and NOTICE material, preserve copyright/attribution notices, identify modifications if any, and do not imply Velocidex endorsement. Verify the exact release assets and notices when preparing the distributable.**

**1.9 Plugin and endpoint validation**

Test evidence	What it proves
Dashboard dispatch	Wazuh API response error=0; affected_items includes selected agent; total_failed_items=0.	Manager accepted/dispatched the request.
Wrapper launch	Timestamped wrapper_debug file or process evidence.	Windows agent launched the CMD wrapper.
PowerShell launch	Timestamped capture log begins with handler-start event.	PowerShell handler started.
STDIN/JSON	Input length, command=add and parsed extra_args.	Wazuh payload reached and parsed by handler.
Argument validation	Case ID, analyst ID, public-key-supplied status and validation success.	The invocation metadata passed validation.
Acquisition	WinPmem capture output, memory size, raw SHA-256.	The acquisition executable completed its capture stage.
Encryption	Encrypted path and encrypted SHA-256.	Encrypted evidence was produced.
Manifest	Manifest path and JSON file exists.	Manifest was written.
Upload	Uploaded=true or confirmed SFTP-side receipt.	Evidence was delivered to the collection server.


**PART 2 — Ubuntu Wazuh server, Tailscale and SFTP collection**

**2.1 Ubuntu server roles**

The Ubuntu host was used for the Wazuh Manager/API and Dashboard environment. The same or a separate Ubuntu host may provide the SFTP evidence-collection service.
Ubuntu 24.04.4 LTS; Wazuh API/manager v4.14.10 was observed.

**2.2 Install and connect Tailscale**

Tailscale provides a private WireGuard-based network between the Windows endpoint and Ubuntu collection server. Install the official Tailscale client on each machine, authenticate both into the same tailnet (or configure approved sharing), and verify that the devices appear online in the Tailscale admin console.
Use the current official Tailscale installation instructions for Ubuntu 24.04 and Windows, and do not reuse an old auth key. On Ubuntu, the common service verification commands are:

sudo systemctl status tailscaled --no-pager
 tailscale status
 tailscale ip -4

On Windows PowerShell:
 tailscale status
 tailscale ip -4
 Test-NetConnection 100.x.x.x -Port 22

Replace 100.x.x.x with the actual current Tailscale IPv4 address of the SFTP server. Test from the endpoint under the same network conditions and service identity context as the acquisition workflow where possible.
If the TCP test times out, check that both devices are online in the same tailnet, the SFTP daemon is listening on TCP/22, Ubuntu host firewall allows the intended Tailscale source, and Tailscale ACL/grants permit the Windows device to reach the server on port 22. A Tailscale ping alone does not prove that TCP/22 is reachable.

**2.3 Tailscale ACL / access policy**

Apply least-privilege access. Permit only the Windows acquisition endpoint (or a tightly scoped device group) to reach the SFTP host on TCP/22. Do not open SSH/SFTP to the public internet merely to make the upload work. policy requirement is:

 policy only — adapt to your tailnet's current grants/ACL schema.
 Allow the designated Windows acquisition device/group to reach
 the designated evidence server on TCP port 22.
 Do not copy this as a complete policy without validating identities/tags.

Use device tags or stable identity groups where appropriate, and document which devices/users are allowed to upload. Keep administrative SSH access separate from the restricted upload account.

**2.4 Install and configure the SFTP service**

The project used an seperate SFTP account and a restricted incoming directory. The design intent was an upload-only account without directory listing. 
the following is a recommended hardened pattern, about the current live server.

Create a dedicated upload-only group and account. A chroot directory must be owned by root and must not be writable by the chrooted user; provide a separate writable incoming subdirectory.

**2.5 Configure the SFTP uploader**

The Go executable's help output stated that uploader.json is loaded from beside the executable. Therefore, the deployed uploader configuration is expected next to memory_capture_go_winpmem.exe.
The exact uploader.json schema and field names are included in the project files. 

Recommended security properties:
⦁	Use the Tailscale IP or stable MagicDNS name of the SFTP server, not a public address.
⦁	Use a dedicated SSH keypair for upload account. keep the private key on the Windows endpoint and install only its public key on the Ubuntu server.
⦁	Protect the private key with restrictive Windows ACLs. Do not include it in the plugin, public-key field, or logs.
⦁	Verify the SFTP server host key. Avoid disabling host-key verification.
⦁	Use a dedicated remote incoming directory and avoid granting shell access or general filesystem access to upload account.
⦁	Do not allow remote directory listing if the application only requires upload.

**2.6 Upload and evidence lifecycle**

The Go executable reported two deliverables: an encrypted memory image with .fmem extension and a JSON manifest. It printed SHA-256 hashes for the raw image and encrypted image. On upload failure it reported that the encrypted file was retained locally. The tested executable reported Uploaded: false while still exiting with code 0, because local acquisition/encryption completed.
Operationally, treat capture, encryption and upload as separate states. The Dashboard should not label the case as fully delivered merely because the executable returned zero. A robust state model is:
State	Meaning	Evidence to record

 REQUEST_DISPATCHED	Wazuh accepted the Active Response request.	Wazuh API response, agent ID, case ID, dispatch timestamp.
 CAPTURE_STARTED	Endpoint handler launched the acquisition program.	Endpoint timestamped log and process start.
 CAPTURE_COMPLETED	Memory image was captured and raw hash computed.	Image metadata, raw SHA-256, capture duration.
 ENCRYPTION_COMPLETED	Encrypted evidence and manifest were produced.	Encrypted file path/size/hash, manifest path.
 UPLOAD_FAILED	SFTP transfer did not complete.	Error category/message; retained local path.
 UPLOAD_COMPLETED	Server acknowledged transfer and destination verified.	Remote receipt/verification record and upload timestamp.

A stronger completion check should verify the expected local files exist and have nonzero size, validate the manifest, and independently verify remote receipt. If remote hash verification is part of the design, compare the server-side encrypted-file SHA-256 against the endpoint's recorded encrypted hash. This behavior is recommended.

**2.8 SFTP destination directory and retention**

Use a dedicated evidence landing area, separate from Wazuh manager data, Dashboard plugin files and operating-system directories. Establish a retention policy, backup policy, access logging, storage monitoring and a procedure for moving verified uploads from the incoming drop folder into controlled evidence storage.
Do not delete local endpoint evidence solely because the SFTP client reports that a transfer started. Delete or securely clean up local evidence only after a documented receipt/verification condition and according to the organization's evidence-retention policy.



**Windows acquisition endpoint**

Path / resource	Recommended access	Reason
Wazuh agent installation tree	SYSTEM and Administrators full control; ordinary users read/execute only where required	Protect agent binaries, configuration and Active Response scripts.
active-response\bin\df-memory-capture.cmd	SYSTEM/Administrators modify; Wazuh service identity read/execute	Prevent unprivileged replacement of the command wrapper.
active-response\bin\df-memory-capture.ps1	SYSTEM/Administrators modify; Wazuh service identity read	PowerShell handler is privileged code and must not be user-writable.
memory_capture_go_winpmem.exe	SYSTEM/Administrators modify; agent service identity read/execute	Protect the acquisition binary from tampering.
uploader.json and SFTP private key	SYSTEM and designated administrators only; private key must be tightly restricted	Protect SFTP credentials and configuration.
Acquisitions	folder SYSTEM and evidence administrators full control; service identity modify; other users no access	Protect local evidence and prevent unauthorized deletion or alteration.
Endpoint timestamped logs	SYSTEM/Administrators and designated responders read; service identity append/create	Preserve audit trail without exposing sensitive secrets.
 
# Secrets and key separation

⦁	Wazuh API username/password: stored only in the Dashboard server environment file; restrict file permissions.
⦁	Analyst X25519 public key: supplied to the endpoint as an encryption recipient key. A public key is not secret, but validate its length/encoding and do not accept arbitrary command-line content.
⦁	SFTP SSH private key: stored on the Windows endpoint, protected by ACLs, and never transmitted as the analyst public key.
⦁	SFTP SSH public key: installed in the restricted upload account's authorized_keys on upload server.
⦁	SFTP server host key: pinned/verified by the uploader to prevent connecting to an impersonated server.
⦁	Do not log passwords, private keys, complete uploader.json contents or other reusable secrets.

# Evidence integrity

⦁	Record raw and encrypted SHA-256 values, case ID, endpoint identity, acquisition timestamp, tool version and upload result in the manifest or associated audit record.
⦁	Preserve the original encrypted artifact and manifest after upload until remote receipt and integrity checks are complete.
⦁	Restrict write access to finalized evidence; use append-only or immutable storage controls if available.
⦁	Document any failed or partial acquisition, including the local retained artifact path and reason upload did not complete.

# End-to-end validation and troubleshooting

Symptom	Likely layer	Checks
Dashboard reports command error / Wazuh 1652	Command registration/name	Confirm command name and executable in manager ossec.conf; use the tested !df-memory-capture.cmd command.
Wazuh API HTTP 400: Invalid field custom	Plugin Active Response request body	Remove unsupported custom:true; inspect response body for Wazuh error details.
Agent missing from plugin list; API error 1724	Agent list query	Use supported select fields: id,name,status,os.name,os.platform,os.version.
No timestamped handler log	Agent dispatch/wrapper launch	Check agent ossec.log, active-responses.log, wrapper debug log, file ACLs and exact deployed script path.
Handler log stops waiting for STDIN	PowerShell input handling	Use [Console]::In.ReadLine(); do not use ReadToEnd() for this Active Response payload.
Arguments absent or misassigned	Dashboard argument contract / parser	Inspect raw JSON extra_args; agree on key=value names and parse case_id, analyst_id, pubkey consistently.
Files appear in agent directory	Acquisition output option	Pass --output C:\DF\Acquisitions\<case-id>; default is current directory.
SFTP TCP timeout to 100.x.x.x:22	Tailscale/network/firewall/sshd	Check tailscale status, TCP/22 listener, ACL/grants, host firewall and route before troubleshooting SSH keys.
SFTP authentication failure	SSH key / account / authorized_keys	Verify correct SFTP private/public key pair, username dfupload, permissions and sshd logs.
Uploaded=false but executable exit code 0	Application completion semantics	Treat local acquisition/encryption success separately from remote delivery; update status model and verify remote receipt.

**Recommended final acceptance test**

1.	Select one authorized Windows test endpoint in the Dashboard and submit a unique case ID.
2.	Confirm the Wazuh API response reports error=0 and the intended agent in affected_items.
3.	Confirm a new timestamped endpoint log is created and records the matching case ID and analyst ID.
4.	Confirm the public key was supplied and validated without logging its private counterpart or sensitive material.
5.	Confirm the acquisition executable reports memory capture completed and records raw SHA-256.
6.	Confirm the encrypted .fmem file and manifest exist under C:\DF\Acquisitions\<case-id> and are non-zero in size.
7.	Confirm the manifest content matches the produced artifact and case metadata.
8.	Confirm TCP/22 is reachable over Tailscale and the SFTP uploader authenticates as upload account.
9.	Confirm both encrypted artifact and manifest are present in the intended remote incoming directory.
10.	Verify the remote encrypted-file hash against the endpoint's encrypted SHA-256 if the design implements remote verification.
11.	Record upload success separately from acquisition success and retain the local copy until the evidence-retention policy permits cleanup.
