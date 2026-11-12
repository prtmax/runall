const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { mkdtemp, readFile, rm } = require('node:fs/promises');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

async function exchange(statuses, { actions = false, out = false } = {}) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'runall-exchange-'));
  const output = path.join(directory, 'credential.env');
  const requests = [];
  const versions = [];
  const ports = [];
  const server = http.createServer(async (request, response) => {
    let body = '';
    for await (const chunk of request) body += chunk;
    requests.push(JSON.parse(body));
    versions.push(request.httpVersion);
    ports.push(request.socket.remotePort);
    const status = statuses[Math.min(requests.length - 1, statuses.length - 1)];
    if (status === 'stall') return;
    if (status === 'partial') {
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.write('{"accessToken":');
      return;
    }
    response.writeHead(status, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify(status === 200
      ? { accessToken: 'stage-credential' }
      : { error: 'temporary exchange error' }));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const child = spawn(path.resolve(__dirname, '../exchange-build-credential'), [
      '--run-id', '900', out ? '--out' : '--output-env', output,
    ], {
      env: {
        ...process.env,
        GITHUB_ACTIONS: String(actions),
        COSMOS_BUILD_AUTH_EXCHANGE_URL: `http://127.0.0.1:${server.address().port}/exchange`,
        COSMOS_BUILD_OIDC_TOKEN: 'test-oidc-token',
      },
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    let stdout = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    const code = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', resolve);
    });
    const credential = await readFile(output, 'utf8').catch((error) => {
      if (error.code === 'ENOENT') return '';
      throw error;
    });
    return { code, requests, credential, versions, ports, stdout };
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await rm(directory, { recursive: true });
  }
}

async function main() {
  const recovered = await exchange([503, 200]);
  assert.equal(recovered.stdout, '', 'local exchanges must never print credentials');
  for (const out of [false, true]) {
    const masked = await exchange([200], { actions: true, out });
    assert.equal(masked.code, 0);
    const token = recovered.credential.replace('COSMOS_BUILD_CREDENTIAL=', '').trim();
    assert.equal(masked.stdout, `::add-mask::${token}\n`);
    assert.equal(masked.credential, out ? `${token}\n` : recovered.credential);
  }
  assert.equal(recovered.code, 0);
  assert.equal(recovered.requests.length, 2);
  assert.deepEqual(recovered.requests[0], { runId: '900', githubOidcToken: 'test-oidc-token' });
  assert.deepEqual(recovered.requests[1], recovered.requests[0]);
  assert.equal(recovered.credential, 'COSMOS_BUILD_CREDENTIAL=stage-credential\n');
  assert.deepEqual(recovered.versions, ['1.1', '1.1']);

  const started = Date.now();
  const reconnected = await exchange(['stall', 200]);
  assert.equal(reconnected.code, 0);
  assert.equal(reconnected.requests.length, 2);
  assert.notEqual(reconnected.ports[0], reconnected.ports[1]);
  assert.ok(Date.now() - started >= 10000);
  assert.ok(Date.now() - started < 23000, 'a stalled attempt must not wait 25 seconds');
  assert.equal(reconnected.credential, 'COSMOS_BUILD_CREDENTIAL=stage-credential\n');

  const partial = await exchange(['partial', 200]);
  assert.equal(partial.code, 0);
  assert.equal(partial.requests.length, 2);
  assert.equal(partial.credential, 'COSMOS_BUILD_CREDENTIAL=stage-credential\n');

  const rejected = await exchange([403]);
  assert.notEqual(rejected.code, 0);
  assert.equal(rejected.requests.length, 1);
  assert.equal(rejected.credential, '');

  const exhausted = await exchange([503]);
  assert.notEqual(exhausted.code, 0);
  assert.equal(exhausted.requests.length, 7);
  assert.equal(exhausted.credential, '');
  console.log('OIDC exchange retries recover transient failures, reject forbidden identities, and stop after seven attempts');
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
