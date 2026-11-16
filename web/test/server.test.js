// Tests server.js against a stand-in for the CarNET API, so no real requests are sent. Run: npm test
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request } from 'node:http';
import { createServer as createTcpServer } from 'node:net';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { resolve } from 'node:path';

const WEB = resolve(import.meta.dirname, '..');

// The stand-in API: answers from the `answers` queue (or "no car" when it is empty) and records each request.
let answers = [];
let received = [];
const api = createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  received.push({ url: req.url, key: req.headers['api-key'], body: Buffer.concat(chunks) });
  const answer = answers.shift() ?? { status: 200, body: { is_success: true, detections: [] } };
  if (answer.delay) await new Promise((done) => setTimeout(done, answer.delay));
  res.writeHead(answer.status, { 'Content-Type': 'application/json', ...answer.headers });
  res.end(typeof answer.body === 'string' ? answer.body : JSON.stringify(answer.body));
});

let site;
let base;
before(async () => {
  api.listen(0, '127.0.0.1');
  await once(api, 'listening');
  ({ child: site, base } = await startSite({ CARNET_API_URL: `http://127.0.0.1:${api.address().port}/detect`, CARNET_API_KEY: 'test-key' }));
});
after(() => {
  site.kill();
  api.close();
});
beforeEach(() => {
  answers = [];
  received = [];
});

const recognize = (body) => fetch(`${base}/api/recognize`, { method: 'POST', body });

const CAR = {
  is_success: true,
  detections: [{
    box: { tl_x: 0.1, tl_y: 0.2, br_x: 0.9, br_y: 0.8 },
    mmg: [{ make_name: 'Porsche', model_name: 'Taycan', generation_name: 'I facelift', years: '2024-', probability: 0.997 }],
    color: [{ name: 'Black', probability: 0.99 }],
    angle: [{ name: 'front-right', probability: 1 }],
  }],
  meta: { time: 0.07 },
};

test('serves the page, with a content policy', async () => {
  const response = await fetch(`${base}/`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /text\/html/);
  assert.match(response.headers.get('content-security-policy'), /default-src 'self'/);
  assert.match(await response.text(), /Which car is this\?/);
});

test('serves nothing from outside the public folder', async () => {
  for (const path of ['/server.js', '/..%2Fserver.js', '/%2e%2e/package.json', '/examples/../../server.js', '/%E0%A4%A']) {
    const response = await fetch(`${base}${path}`);
    assert.equal(response.status, 404, path);
  }
});

test('sends the photo to the API with the key and the parameters, and passes the answer on', async () => {
  answers.push({ status: 200, body: CAR });
  const response = await recognize('PHOTO BYTES');
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), CAR);
  assert.equal(received.length, 1);
  assert.equal(received[0].key, 'test-key');
  assert.equal(received[0].url, '/detect?features=mmg,color,angle&box_select=all');
  assert.equal(received[0].body.toString(), 'PHOTO BYTES');
});

test('refuses a photo over 12 MB without calling the API', async () => {
  const response = await recognize(Buffer.alloc(12 * 1024 * 1024 + 1));
  assert.equal(response.status, 413);
  assert.match((await response.json()).error, /larger than 12 MB/);
  assert.equal(received.length, 0);
});

test('refuses a photo that says it is over 12 MB before reading it', async () => {
  const status = await new Promise((done, fail) => {
    const req = request(`${base}/api/recognize`, { method: 'POST', headers: { 'Content-Length': 14 * 1024 * 1024 } });
    req.on('response', (response) => done(response.statusCode));
    req.on('error', fail);
    req.write(Buffer.alloc(1024)); // only the start: the answer must not wait for the rest
  });
  assert.equal(status, 413);
  assert.equal(received.length, 0);
});

test('more than 4 photos at once: the fifth is told the site is busy', async () => {
  for (let i = 0; i < 4; i++) answers.push({ status: 200, body: CAR, delay: 500 });
  const statuses = (await Promise.all([1, 2, 3, 4, 5].map(async (n) => {
    if (n === 5) await new Promise((done) => setTimeout(done, 150)); // the first four are with the API by then
    const response = await recognize(`PHOTO ${n}`);
    return [response.status, (await response.json()).error];
  })));
  assert.deepEqual(statuses.slice(0, 4).map(([status]) => status), [200, 200, 200, 200]);
  assert.equal(statuses[4][0], 503);
  assert.match(statuses[4][1], /busy/);
  assert.equal(received.length, 4);
});

test('refuses an empty request', async () => {
  const response = await recognize('');
  assert.equal(response.status, 400);
  assert.equal(received.length, 0);
});

test('too fast for the key: waits for the next second and tries once more', async () => {
  answers.push({
    status: 429,
    body: { message: 'Rate limit exceeded ! You reach the limit of 1 requests per 1 seconds', http_status_code: 429 },
    headers: { 'X-Rate-Limit-Reset': String(Date.now() + 300) },
  });
  answers.push({ status: 200, body: CAR });
  const started = Date.now();
  const response = await recognize('PHOTO');
  assert.equal(response.status, 200);
  assert.equal(received.length, 2);
  assert.ok(Date.now() - started >= 100, 'it waited');
});

test("the key's limit used up: says so and doesn't retry", async () => {
  answers.push({ status: 429, body: { message: 'Quota exceeded ! You reach the limit of 100 requests per 1 days', http_status_code: 429 } });
  const response = await recognize('PHOTO');
  assert.equal(response.status, 429);
  assert.match((await response.json()).error, /used up/);
  assert.equal(received.length, 1);
});

test('a refused key is reported as the site owner\'s problem', async () => {
  answers.push({ status: 403, body: { message: 'API Key is not valid or is expired / revoked.', http_status_code: 403 } });
  const response = await recognize('PHOTO');
  assert.equal(response.status, 502);
  assert.match((await response.json()).error, /refused this site's API key/);
});

test('a server error or an unreadable answer gives a plain error', async () => {
  answers.push({ status: 500, body: 'oops' });
  assert.equal((await recognize('PHOTO')).status, 502);
  answers.push({ status: 200, body: '<html>not json</html>' });
  const response = await recognize('PHOTO');
  assert.equal(response.status, 502);
  assert.match((await response.json()).error, /could not read/);
});

test("a photo the API can't read: its answer is passed on", async () => {
  const unreadable = { is_success: false, error: { code: 8, message: 'Error decoding image' }, detections: [] };
  answers.push({ status: 200, body: unreadable });
  const response = await recognize('NOT A PHOTO');
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), unreadable);
});

test('no answer from the API gives a plain error', async () => {
  const closed = await freePort();
  const { child, base: other } = await startSite({ CARNET_API_URL: `http://127.0.0.1:${closed}/detect`, CARNET_API_KEY: 'test-key' });
  try {
    const response = await fetch(`${other}/api/recognize`, { method: 'POST', body: 'PHOTO' });
    assert.equal(response.status, 502);
    assert.match((await response.json()).error, /did not answer/);
  } finally {
    child.kill();
  }
});

test('without a key for the Cloud API it stops and says why', async () => {
  const child = spawn(process.execPath, ['server.js'], { cwd: WEB, env: { PATH: process.env.PATH, PORT: String(await freePort()) } });
  let errors = '';
  child.stderr.on('data', (chunk) => { errors += chunk; });
  const [code] = await once(child, 'exit');
  assert.equal(code, 1);
  assert.match(errors, /Set your API key first/);
});

async function startSite(env) {
  const port = await freePort();
  const child = spawn(process.execPath, ['server.js'], {
    cwd: WEB,
    env: { PATH: process.env.PATH, PORT: String(port), HOST: '127.0.0.1', ...env },
    stdio: 'ignore',
  });
  const url = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 50; i++) {
    try {
      if ((await fetch(`${url}/`)).ok) return { child, base: url };
    } catch {}
    await new Promise((done) => setTimeout(done, 100));
  }
  child.kill();
  throw new Error('server.js did not start');
}

async function freePort() {
  const server = createTcpServer().listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  server.close();
  return port;
}
