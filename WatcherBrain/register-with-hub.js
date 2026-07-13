// Runs once per machine: exchanges the shared enrollment secret (baked into
// this install package, see HubConfig.json) for a unique per-machine
// credential. Safe to call repeatedly — no-ops if hub-credential.json
// already exists. Called automatically by poll-hub.js if it finds no
// credential yet (e.g. the PC was offline during install).
'use strict';

const os = require('os');
const { execFileSync } = require('child_process');
const { readHubConfig, readCredential, writeCredential, postJson } = require('./hub-client');

// Stable per-PC fingerprint so a reinstall re-claims this machine's existing
// dashboard row instead of creating a duplicate ghost. Windows MachineGuid
// lives at HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid and survives
// reinstalling Watcher (it's tied to the Windows install/hardware, not to us).
// Returns null on any failure - the hub then falls back to old always-insert
// behavior, so registration still works, just without de-duplication.
function getHardwareId() {
    try {
        const out = execFileSync(
            'reg.exe',
            ['query', 'HKLM\\SOFTWARE\\Microsoft\\Cryptography', '/v', 'MachineGuid'],
            { encoding: 'utf-8', timeout: 10000 }
        );
        // Output line looks like: "    MachineGuid    REG_SZ    <guid>"
        const m = out.match(/MachineGuid\s+REG_SZ\s+([0-9a-fA-F-]{36})/);
        return m ? m[1].toLowerCase() : null;
    } catch (e) {
        return null;
    }
}

async function registerIfNeeded() {
    const existing = readCredential();
    if (existing) return existing;

    const config = readHubConfig();
    const label = `${os.hostname()}`;
    const hardwareId = getHardwareId();

    const result = await postJson(config.HubUrl, '/api/agent/register', {
        enrollment_secret: config.EnrollmentSecret,
        label,
        hardware_id: hardwareId,
    });

    if (!result || !result.machine_id || !result.credential) {
        throw new Error('hub did not return a machine_id/credential on registration');
    }

    writeCredential(result.machine_id, result.credential);
    return { machine_id: result.machine_id, credential: result.credential };
}

if (require.main === module) {
    registerIfNeeded()
        .then((cred) => {
            console.log(`Registered as machine ${cred.machine_id}`);
            process.exit(0);
        })
        .catch((err) => {
            console.error('Registration failed:', err.message);
            process.exit(1);
        });
}

module.exports = { registerIfNeeded };
