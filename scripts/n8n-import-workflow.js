// Runs *inside* the n8n pod (via `kubectl exec`) to import and activate
// n8n/order-validation.json. Node's built-in fetch is used deliberately -
// the n8n image's busybox wget can't do PATCH/PUT at all (no --method flag)
// and mangles JSON piped through multiple shell layers, both of which broke
// this step in earlier versions of up.sh. See ISSUE.md #2 addendum for the
// full root-cause history (n8n's :latest tag drifted far enough that the
// workflow JSON's node versions, response mode, and auth assumptions were
// all stale - none of this is n8n-version-agnostic, it will need revisiting
// again if/when the pinned image version changes).
//
// Usage: node n8n-import-workflow.js <workflow.json path> <owner email> <owner password>
const fs = require("fs");

const BASE = "http://localhost:5678";
const [, , workflowPath, email, password] = process.argv;

async function main() {
  const settings = await (await fetch(`${BASE}/rest/settings`)).json();
  if (settings.data.userManagement.showSetupOnFirstLoad) {
    console.log("Owner not set up yet, creating owner account");
    const setupRes = await fetch(`${BASE}/rest/owner/setup`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, firstName: "Admin", lastName: "User", password }),
    });
    if (!setupRes.ok) throw new Error(`owner setup failed: ${setupRes.status} ${await setupRes.text()}`);
  }

  const loginRes = await fetch(`${BASE}/rest/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ emailOrLdapLoginId: email, password }),
  });
  if (!loginRes.ok) throw new Error(`login failed: ${loginRes.status} ${await loginRes.text()}`);
  const cookie = loginRes.headers.get("set-cookie").split(";")[0];
  const authedHeaders = { "Content-Type": "application/json", Cookie: cookie };

  const workflowJson = JSON.parse(fs.readFileSync(workflowPath, "utf8"));

  // Idempotent: archive+delete any existing workflow(s) with the same name
  // before importing fresh, rather than leaving duplicates on every re-run.
  const existing = await (await fetch(`${BASE}/rest/workflows`, { headers: { Cookie: cookie } })).json();
  for (const wf of existing.data.filter((w) => w.name === workflowJson.name)) {
    if (wf.active) {
      await fetch(`${BASE}/rest/workflows/${wf.id}/deactivate`, {
        method: "POST",
        headers: authedHeaders,
        body: "{}",
      });
    }
    await fetch(`${BASE}/rest/workflows/${wf.id}/archive`, {
      method: "POST",
      headers: authedHeaders,
      body: "{}",
    });
    const delRes = await fetch(`${BASE}/rest/workflows/${wf.id}`, { method: "DELETE", headers: { Cookie: cookie } });
    console.log(`Removed existing workflow ${wf.id}: ${delRes.status}`);
  }

  const importRes = await fetch(`${BASE}/rest/workflows`, {
    method: "POST",
    headers: authedHeaders,
    body: JSON.stringify(workflowJson),
  });
  if (!importRes.ok) throw new Error(`import failed: ${importRes.status} ${await importRes.text()}`);
  const imported = (await importRes.json()).data;
  console.log(`Imported workflow ${imported.id} (versionId ${imported.versionId})`);

  const activateRes = await fetch(`${BASE}/rest/workflows/${imported.id}/activate`, {
    method: "POST",
    headers: authedHeaders,
    body: JSON.stringify({ versionId: imported.versionId }),
  });
  if (!activateRes.ok) throw new Error(`activate failed: ${activateRes.status} ${await activateRes.text()}`);
  const activated = (await activateRes.json()).data;
  if (!activated.active) throw new Error("activate call succeeded but workflow is still not active");
  console.log(`Activated workflow ${imported.id}`);
}

main().catch((err) => {
  console.error("ERROR:", err.message);
  process.exit(1);
});
