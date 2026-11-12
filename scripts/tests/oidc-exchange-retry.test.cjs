const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { mkdtemp, readFile, rm } = require('node:fs/promises');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

async function exchange(statuses) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'runall-exchange-'));
  const output = path.join(directory, 'credential.env');
  const requests = [];
  const server = http.createServer(async (request, response) => {
    let body = '';
    for await (const chunk of request) body += chunk;
    requests.push(JSON.parse(body));
    const status = statuses[Math.min(requests.length - 1, statuses.length - 1)];
    response.writeHead(status, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify(status === 200
      ? { accessToken: 'stage-credential' }
      : { error: 'temporary exchange error' }));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const child = spawn(path.resolve(__dirname, '../exchange-build-credential'), [
      '--run-id', '900', '--output-env', output,
    ], {
      env: {
        ...process.env,
        COSMOS_BUILD_AUTH_EXCHANGE_URL: `http://127.0.0.1:${server.address().port}/exchange`,
        COSMOS_BUILD_OIDC_TOKEN: 'test-oidc-token',
      },
      stdio: 'ignore',
    });
    const code = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', resolve);
    });
    const credential = await readFile(output, 'utf8').catch((error) => {
      if (error.code === 'ENOENT') return '';
      throw error;
    });
    return { code, requests, credential };
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await rm(directory, { recursive: true });
  }
}

async function main() {
  const recovered = await exchange([503, 200]);
  assert.equal(recovered.code, 0);
  assert.equal(recovered.requests.length, 2);
  assert.deepEqual(recovered.requests[0], { runId: '900', githubOidcToken: 'test-oidc-token' });
  assert.deepEqual(recovered.requests[1], recovered.requests[0]);
  assert.equal(recovered.credential, 'COSMOS_BUILD_CREDENTIAL=stage-credential\n');

  const rejected = await exchange([403]);
  assert.notEqual(rejected.code, 0);
  assert.equal(rejected.requests.length, 1);
  assert.equal(rejected.credential, '');

  const exhausted = await exchange([503]);
  assert.notEqual(exhausted.code, 0);
  assert.equal(exhausted.requests.length, 3);
  assert.equal(exhausted.credential, '');
  console.log('OIDC exchange retries recover transient failures, reject forbidden identities, and stop after three attempts');
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
