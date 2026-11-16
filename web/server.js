// CarNET API micro website: serves the page and sends each photo on to the CarNET API with your key.
//
// The key stays on this server: the page never sees it. (The API doesn't take calls straight from other sites'
// pages either, so a page always needs a server like this one.)
//
// Needs Node.js 22 or later, and no packages. Part of https://github.com/OneStar-dev/CarNET.ai.samples (MIT licence).

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, resolve, sep } from 'node:path';

const API_URL = process.env.CARNET_API_URL || 'https://api.carnet.ai/v2/mmg/detect';
const API_KEY = process.env.CARNET_API_KEY || '';
const PORT = Number(process.env.PORT || 8080);
const HOST = process.env.HOST || 'localhost';

// What we ask the API for: make, model and generation, body color and angle, for every car in the photo.
// Add region=NA to use the network trained for North America.
const QUERY = 'features=mmg,color,angle&box_select=all';
const TARGET = API_URL + (API_URL.includes('?') ? '&' : '?') + QUERY;

const MAX_BYTES = 12 * 1024 * 1024; // the Cloud API takes photos up to 12 MB
const PUBLIC = resolve(import.meta.dirname, 'public');
const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.jpg': 'image/jpeg',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
};
// The page loads nothing from other sites; photos are shown from memory (blob:).
const PAGE_POLICY = "default-src 'self'; img-src 'self' blob:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'";

if (!API_KEY && API_URL.startsWith('https://api.carnet.ai/')) {
  console.error('Set your API key first: CARNET_API_KEY=your-key node server.js');
  console.error('Get a free trial key at https://carnet.ai');
  process.exit(1);
}

const server = createServer(async (req, res) => {
  try {
    const path = new URL(req.url, 'http://localhost').pathname;
    if (path === '/api/recognize') {
      if (req.method !== 'POST') return send(res, 405, { error: 'Send the photo with POST.' });
      return await recognize(req, res);
    }
    if (req.method === 'GET' || req.method === 'HEAD') return await serveFile(path, req, res);
    send(res, 405, { error: 'Not allowed.' });
  } catch (error) {
    console.error(error);
    if (!res.headersSent) send(res, 500, { error: 'Something went wrong on this server.' });
    else res.destroy();
  }
});

server.listen(PORT, HOST, () => {
  console.log(`Car recognition demo: http://${HOST === '0.0.0.0' ? 'localhost' : HOST}:${PORT}`);
  console.log(`Sends photos to ${API_URL}${API_KEY ? ' with your key' : ' without a key'}`);
});

// POST /api/recognize: the photo's bytes in the body. Answers with the API's own JSON, or { error } when
// something went wrong, in words the page can show as they are.
async function recognize(req, res) {
  const photo = await readBody(req);
  if (photo === null) return send(res, 413, { error: 'The photo is larger than 12 MB.' });
  if (photo.length === 0) return send(res, 400, { error: 'No photo was sent.' });

  let answer = await callApi(photo);
  // Too fast for the key's per-second limit (two visitors at once, say): wait for the next second, try once more.
  if (answer.status === 429 && !answer.text.includes('Quota exceeded')) {
    await new Promise((done) => setTimeout(done, waitForRate(answer.headers)));
    answer = await callApi(photo);
  }

  const { status, text } = answer;
  if (status === 0) return send(res, 502, { error: 'The recognition service did not answer. Try again in a moment.' });
  if (status === 429 && text.includes('Quota exceeded')) {
    return send(res, 429, { error: "This site's limit of photos is used up for now. Try again later." });
  }
  if (status === 429) return send(res, 429, { error: 'Too many photos at once. Try again in a second.' });
  if (status === 401 || status === 403) {
    return send(res, 502, { error: "The recognition service refused this site's API key. The site's owner needs to check it." });
  }
  if (status === 413) return send(res, 413, { error: 'The photo is larger than 12 MB.' });
  if (status >= 500) return send(res, 502, { error: 'The recognition service had a problem. Try again in a moment.' });

  let json;
  try {
    json = JSON.parse(text);
  } catch {
    return send(res, 502, { error: 'The recognition service gave an answer this site could not read.' });
  }
  send(res, 200, json); // a photo the API couldn't read comes back as is_success: false with error.message
}

// One request to the API. status 0 means no answer (network error or timeout).
async function callApi(photo) {
  const started = Date.now();
  try {
    const response = await fetch(TARGET, {
      method: 'POST',
      headers: { 'Content-Type': 'application/octet-stream', ...(API_KEY && { 'api-key': API_KEY }) },
      body: photo,
      signal: AbortSignal.timeout(30_000),
    });
    const text = await response.text();
    const left = response.headers.get('x-quota-remaining');
    log(`${response.status}, ${photo.length} bytes, ${Date.now() - started} ms${left === null ? '' : `, ${left} requests left`}`);
    return { status: response.status, headers: response.headers, text };
  } catch (error) {
    log(`no answer after ${Date.now() - started} ms: ${error.message}`);
    return { status: 0, headers: new Headers(), text: '' };
  }
}

// Milliseconds until the per-second count starts again (X-Rate-Limit-Reset is a Unix time in milliseconds),
// kept between 0.1 and 1.1 seconds so a clock that is off can't make anyone wait long.
function waitForRate(headers) {
  const reset = Number(headers.get('x-rate-limit-reset'));
  if (!reset) return 1000;
  return Math.min(Math.max(reset - Date.now(), 100), 1100);
}

// The request body, or null when it is larger than the API accepts.
function readBody(req) {
  return new Promise((done, fail) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size <= MAX_BYTES) chunks.push(chunk);
    });
    req.on('end', () => done(size > MAX_BYTES ? null : Buffer.concat(chunks)));
    req.on('error', fail);
  });
}

// The page and its files, from ./public only.
async function serveFile(path, req, res) {
  let file;
  try {
    file = resolve(PUBLIC, '.' + decodeURIComponent(path === '/' ? '/index.html' : path));
  } catch {
    return send(res, 404, { error: 'Not found.' });
  }
  if (!file.startsWith(PUBLIC + sep)) return send(res, 404, { error: 'Not found.' });
  let body;
  try {
    body = await readFile(file);
  } catch {
    return send(res, 404, { error: 'Not found.' });
  }
  const type = TYPES[extname(file)] || 'application/octet-stream';
  res.writeHead(200, {
    'Content-Type': type,
    'Content-Length': body.length,
    'Cache-Control': 'no-cache',
    'X-Content-Type-Options': 'nosniff',
    ...(type.startsWith('text/html') && { 'Content-Security-Policy': PAGE_POLICY }),
  });
  res.end(req.method === 'HEAD' ? undefined : body);
}

function send(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(text),
    'Cache-Control': 'no-store',
  });
  res.end(text);
}

function log(line) {
  console.log(`${new Date().toISOString()} ${line}`);
}
