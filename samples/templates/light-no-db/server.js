import http from 'http';
import { URL } from 'url';

const port = Number(process.env.PORT || 3000);
const title = process.env.APP_TITLE || "Light No-DB App";
const envKeys = [
  "PORT",
  "APP_PORT",
  "GUI_PORT",
  "API_PORT",
  "DB_MACHINE_ID",
  "DB_HOST",
  "DB_PORT",
  "MYSQL_HOST",
  "MYSQL_PORT",
  "DB_NAME",
  "DB_USER",
  "ACTIVE_CONNECTOR",
  "PUBLIC_URL",
  "API_BASE_URL"
];

function envSummary() {
  return envKeys.reduce((acc, key) => {
    acc[key] = process.env[key] || '';
    return acc;
  }, {});
}

function htmlPage() {
  const env = envSummary();
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title><style>body{font-family:system-ui,sans-serif;max-width:900px;margin:40px auto;padding:0 20px;line-height:1.5}code,pre{background:#f5f5f5;padding:2px 5px;border-radius:4px}.card{border:1px solid #ddd;border-radius:12px;padding:16px;margin:16px 0}</style></head><body><h1>${title}</h1><p>Template skeleton for Multidev install testing.</p><div class="card"><h2>Config</h2><pre>${JSON.stringify(env, null, 2)}</pre></div><div class="card"><h2>Install contract</h2><p>This repo must keep a root <code>package.json</code> with <code>start</code> so Multidev can detect the runtime without manual rescue.</p></div></body></html>`;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (url.pathname === '/api/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, name: "light-no-db", port }));
    return;
  }
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(htmlPage());
});

server.listen(port, () => console.log(`${title} listening on http://127.0.0.1:${port}`));
