// Run the Lambda handler behind a plain HTTP server so you can develop without AWS.
//   npm run dev   ->   http://localhost:8080
import { createServer } from 'node:http';
import { handler } from '../src/index.mjs';

const port = Number(process.env.PORT ?? 8080);

createServer(async (req, res) => {
  const path = new URL(req.url, 'http://localhost').pathname;
  const event = { requestContext: { http: { method: req.method, path } } };

  try {
    const out = await handler(event);
    res.writeHead(out.statusCode, out.headers);
    res.end(out.body);
    console.log(`${req.method} ${path} -> ${out.statusCode}`);
  } catch (err) {
    res.writeHead(500, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: String(err) }));
    console.error(err);
  }
}).listen(port, () => {
  console.log(`hello-aws listening on http://localhost:${port}`);
});
