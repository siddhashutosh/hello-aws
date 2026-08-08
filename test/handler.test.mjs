import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handler, pathOf, json } from '../src/index.mjs';

const req = (path) => ({ requestContext: { http: { method: 'GET', path } } });

test('pathOf reads the Function URL payload shape', () => {
  assert.equal(pathOf(req('/health')), '/health');
});

test('pathOf falls back to rawPath, then to /', () => {
  assert.equal(pathOf({ rawPath: '/x' }), '/x');
  assert.equal(pathOf({}), '/');
});

test('json sets a JSON content type and no-store', () => {
  const res = json(200, { a: 1 });
  assert.equal(res.headers['content-type'], 'application/json; charset=utf-8');
  assert.equal(res.headers['cache-control'], 'no-store');
  assert.deepEqual(JSON.parse(res.body), { a: 1 });
});

test('GET /health reports ok', async () => {
  const res = await handler(req('/health'));
  assert.equal(res.statusCode, 200);
  assert.equal(JSON.parse(res.body).status, 'ok');
});

test('GET / says hello and reports the environment', async () => {
  const res = await handler(req('/'));
  assert.equal(res.statusCode, 200);
  const body = JSON.parse(res.body);
  assert.equal(body.message, 'Hello, world 2!');
  assert.equal(body.env, process.env.ENV ?? 'local');
});

test('GET / degrades gracefully with no table configured', async () => {
  // TABLE is unset in tests, so the DynamoDB client is never constructed.
  const body = JSON.parse((await handler(req('/'))).body);
  assert.equal(body.visits, null);
  assert.equal(body.dbError, undefined);
});

test('unknown paths return 404', async () => {
  const res = await handler(req('/nope'));
  assert.equal(res.statusCode, 404);
  assert.equal(JSON.parse(res.body).path, '/nope');
});
