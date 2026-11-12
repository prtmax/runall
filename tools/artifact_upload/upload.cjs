// Upload per-run artifacts from one prepare job without creating matrix jobs
// that repeat source checkout or exposing credentials to compile jobs.
const fs = require('node:fs');
const path = require('node:path');

function files(root) {
  return fs.readdirSync(root, { withFileTypes: true }).flatMap(entry => {
    const file = path.join(root, entry.name);
    if (entry.isSymbolicLink()) throw new Error('Unexpected artifact symlink');
    return entry.isDirectory() ? files(file) : [file];
  });
}

async function main() {
  const manifest = JSON.parse(fs.readFileSync(process.env.INPUT_MANIFEST || process.argv[2], 'utf8'));
  const { DefaultArtifactClient } = await import('@actions/artifact');
  const client = new DefaultArtifactClient();
  for (const item of manifest) {
    const root = path.resolve(item.root);
    const entries = files(root);
    if (!entries.length) throw new Error('Prepared artifact is empty');
    await client.uploadArtifact(item.name, entries, root, { retentionDays: item.days });
  }
}

main().catch(() => { console.error('Prepared artifact upload failed'); process.exitCode = 1; });
