import http from 'node:http';
import fs from 'node:fs';

const [portFile, logFile] = process.argv.slice(2);
if (!portFile || !logFile) process.exit(64);

function collect(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks)));
  });
}

function reply(res, status, body = '', headers = {}) {
  res.writeHead(status, { 'Content-Type': 'application/json', ...headers });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  const body = await collect(req);
  const record = {
    method: req.method,
    url: req.url,
    authorization: req.headers.authorization ?? '',
    resource_keys: req.headers['x-goog-drive-resource-keys'] ?? '',
    content_range: req.headers['content-range'] ?? '',
    body: body.toString('utf8'),
  };
  fs.appendFileSync(logFile, JSON.stringify(record) + '\n');

  if (record.authorization !== 'Bearer SECRET_TOKEN_VALUE') {
    reply(res, 401, '{"error":"missing token"}');
    return;
  }

  if (req.method === 'GET' && req.url?.startsWith('/drive/v3/files?')) {
    reply(res, 200, '{"files":[],"nextPageToken":"NEXT123"}');
    return;
  }

  if (req.method === 'POST' && req.url === '/drive/v3/files/FILE123/permissions?supportsAllDrives=true') {
    reply(res, 200, '{"id":"PERM123"}');
    return;
  }

  if (req.method === 'POST' && req.url === '/upload/drive/v3/files?uploadType=resumable') {
    reply(res, 200, '', { Location: `http://127.0.0.1:${server.address().port}/session/ABC` });
    return;
  }

  if (req.method === 'PUT' && req.url === '/session/ABC') {
    if (record.content_range === 'bytes 0-9/10') {
      reply(res, 308, '', { Range: 'bytes=0-3' });
      return;
    }
    if (record.content_range === 'bytes 4-9/10' && record.body === '567890') {
      reply(res, 200, '{"id":"UPLOADED"}');
      return;
    }
    reply(res, 400, '{"error":"bad upload range"}');
    return;
  }

  if (req.method === 'PUT' && req.url === '/session/RESUME') {
    if (record.content_range === 'bytes */10' && body.length === 0) {
      reply(res, 308, '', { Range: 'bytes=0-3' });
      return;
    }
    if (record.content_range === 'bytes 4-9/10' && record.body === '567890') {
      reply(res, 200, '{"id":"RESUMED"}');
      return;
    }
    reply(res, 400, '{"error":"bad resume range"}');
    return;
  }

  reply(res, 404, '{"error":"not found"}');
});

server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(portFile, String(server.address().port));
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
