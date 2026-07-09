// Runs once per machine: exchanges the shared enrollment secret (baked into
// this install package, see HubConfig.json) for a unique per-machine
// credential. Safe to call repeatedly — no-ops if hub-credential.json
// already exists. Called automatically by poll-hub.js if it finds no
// credential yet (e.g. the PC was offline during install).
'use strict';

const os = require('os');
const { readHubConfig, readCredential, writeCredential, postJson } = require('./hub-client');

async function registerIfNeeded() {
    const existing = readCredential();
    if (existing) return existing;

    const config = readHubConfig();
    const label = `${os.hostname()}`;

    const result = await postJson(config.HubUrl, '/api/agent/register', {
        enrollment_secret: config.EnrollmentSecret,
        label,
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
