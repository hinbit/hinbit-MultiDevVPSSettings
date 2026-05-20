#!/usr/bin/env node
import fs from 'fs';
import path from 'path';
import http from 'http';
import { execFileSync, spawnSync } from 'child_process';
import os from 'os';
import { fileURLToPath } from 'url';

const META_DIR = '/etc/vps-projects';
const AUTH_DIR = '/etc/nginx/project-auth';
const SYSTEM_ENV_FILE = '/etc/vps-system.env';
const PROJECTCTL = '/usr/local/bin/projectctl';
const PM2 = 'pm2';
const BASIC_USER = 'manage';
const PORT = Number(process.env.MANAGE_PORT || 8090);
const PASSWORD = process.env.MANAGE_PASSWORD || '';
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ENV_CANDIDATES = [
  '.env',
  '.env.local',
  '.env.production',
  '.env.credentials',
  '.env.machine',
  '.env.production.local',
  '.env.development',
];

function loadSystemEnv() {
  if (!fs.existsSync(SYSTEM_ENV_FILE)) return;
  const content = fs.readFileSync(SYSTEM_ENV_FILE, 'utf8');
  for (const line of content.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const idx = trimmed.indexOf('=');
    if (idx === -1) continue;
    const key = trimmed.slice(0, idx).trim();
    const value = trimmed.slice(idx + 1).trim();
    if (key === 'MANAGE_PASSWORD' && !process.env.MANAGE_PASSWORD) {
      process.env.MANAGE_PASSWORD = value;
    }
  }
}

loadSystemEnv();

function die(msg) {
  const err = new Error(msg);
  err.statusCode = 500;
  throw err;
}

function slugFromRef(ref) {
  return String(ref || '')
    .replace(/^git@github.com:/, '')
    .replace(/^https:\/\/github.com\//, '')
    .replace(/^github.com:/, '')
    .replace(/\.git$/, '')
    .replace(/\//g, '-')
    .replace(/[^A-Za-z0-9._-]/g, '-');
}

function repoRefFromArg(ref) {
  const cleaned = String(ref || '')
    .replace(/^git@github.com:/, '')
    .replace(/^https:\/\/github.com\//, '')
    .replace(/^github.com:/, '')
    .replace(/\.git$/, '');
  if (!cleaned.includes('/')) {
    throw new Error(`Expected owner/repo, got: ${ref}`);
  }
  return cleaned;
}

function metaPathForRef(ref) {
  return path.join(META_DIR, `${slugFromRef(ref)}.env`);
}

function parseEnvFile(filePath) {
  const data = {};
  if (!fs.existsSync(filePath)) return data;
  for (const rawLine of fs.readFileSync(filePath, 'utf8').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const idx = line.indexOf('=');
    if (idx === -1) continue;
    const key = line.slice(0, idx).trim();
    const value = line.slice(idx + 1).trim();
    data[key] = value;
  }
  return data;
}

function readProjectEnv(projectPath) {
  const merged = {};
  const files = [];
  for (const name of ENV_CANDIDATES) {
    const filePath = path.join(projectPath, name);
    if (!fs.existsSync(filePath)) continue;
    files.push(filePath);
    Object.assign(merged, parseEnvFile(filePath));
  }

  return { merged, files };
}

function readPackageScripts(projectPath) {
  try {
    const pkgPath = path.join(projectPath, 'package.json');
    if (!fs.existsSync(pkgPath)) return [];
    const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
    const scripts = pkg && pkg.scripts ? pkg.scripts : {};
    return Object.entries(scripts).map(([name, command]) => ({ name, command: String(command) }));
  } catch {
    return [];
  }
}

function readProjects() {
  const projectFiles = fs.existsSync(META_DIR)
    ? fs.readdirSync(META_DIR).filter((name) => name.endsWith('.env'))
    : [];
  return projectFiles.map((name) => {
    const meta = parseEnvFile(path.join(META_DIR, name));
    const authFile = meta.APP_DOMAIN ? path.join(AUTH_DIR, `${meta.APP_DOMAIN}.htpasswd`) : '';
    const protectedAccess = authFile ? fs.existsSync(authFile) && fs.statSync(authFile).size > 0 : false;
    const pm2Name = meta.PM2_NAME || '';
    return {
      ...meta,
      PROJECT_SLUG: meta.PROJECT_SLUG || name.replace(/\.env$/, ''),
      protected: protectedAccess,
      auth_file: authFile,
      repo: meta.REPO_REF || '',
      scripts: readPackageScripts(meta.APP_DIR || ''),
    };
  }).sort((a, b) => String(a.APP_DOMAIN || a.PROJECT_SLUG).localeCompare(String(b.APP_DOMAIN || b.PROJECT_SLUG)));
}

function pickDbDetails(projectPath) {
  const { merged, files } = readProjectEnv(projectPath);
  const keys = [
    'DB_SUPPLIER',
    'DB_NAME',
    'DB_DATABASE',
    'DB_USER',
    'DB_PASSWORD',
    'DB_HOST',
    'DB_PORT',
    'MYSQL_DATABASE',
    'MYSQL_USER',
    'MYSQL_PASSWORD',
    'MYSQL_HOST',
    'MYSQL_PORT',
    'POSTGRES_DB',
    'POSTGRES_USER',
    'POSTGRES_PASSWORD',
    'POSTGRES_HOST',
    'POSTGRES_PORT',
    'DATABASE_URL',
  ];
  const db = {};
  for (const key of keys) {
    if (merged[key]) db[key] = merged[key];
  }
  return { files, db };
}

function pickEnvDetails(projectPath) {
  const { merged, files } = readProjectEnv(projectPath);
  return { files, env: merged };
}

function runPython(script, args = []) {
  const res = spawnSync('python3', ['-c', script, ...args], {
    encoding: 'utf8',
    maxBuffer: 20 * 1024 * 1024,
  });
  if (res.error) throw res.error;
  if (res.status !== 0) {
    throw new Error((res.stderr || res.stdout || 'python3 failed').trim());
  }
  return (res.stdout || '').trim();
}

function createEnvZip(projectPath) {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vps-env-'));
  const zipPath = path.join(tmpDir, 'project-env.zip');
  const filesJson = JSON.stringify(ENV_CANDIDATES);
  runPython(
    `
import json, os, sys, zipfile
project = sys.argv[1]
zip_path = sys.argv[2]
files = json.loads(sys.argv[3])
with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
    for name in files:
        src = os.path.join(project, name)
        if os.path.isfile(src):
            zf.write(src, arcname=name)
print(zip_path)
`,
    [projectPath, zipPath, filesJson],
  );
  const data = fs.readFileSync(zipPath);
  fs.rmSync(tmpDir, { recursive: true, force: true });
  return data;
}

function replaceEnvZip(projectPath, zipBuffer) {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vps-env-up-'));
  const zipPath = path.join(tmpDir, 'upload.zip');
  const extractDir = path.join(tmpDir, 'extract');
  fs.writeFileSync(zipPath, zipBuffer);
  fs.mkdirSync(extractDir, { recursive: true });
  const filesJson = JSON.stringify(ENV_CANDIDATES);
  runPython(
    `
import json, os, pathlib, sys, zipfile
zip_path = sys.argv[1]
extract_dir = sys.argv[2]
allowed = set(json.loads(sys.argv[3]))
with zipfile.ZipFile(zip_path) as zf:
    for info in zf.infolist():
        name = info.filename.replace('\\\\', '/')
        if not name or name.endswith('/'):
            continue
        if '/' in name or '\\\\' in name:
            raise SystemExit(f'Invalid zip entry: {name}')
        if name not in allowed:
            continue
        zf.extract(info, extract_dir)
print(extract_dir)
`,
    [zipPath, extractDir, filesJson],
  );

  for (const name of ENV_CANDIDATES) {
    const target = path.join(projectPath, name);
    if (fs.existsSync(target)) {
      fs.rmSync(target, { force: true });
    }
  }

  for (const name of ENV_CANDIDATES) {
    const source = path.join(extractDir, name);
    if (!fs.existsSync(source)) continue;
    fs.copyFileSync(source, path.join(projectPath, name));
    fs.chmodSync(path.join(projectPath, name), 0o600);
  }

  fs.rmSync(tmpDir, { recursive: true, force: true });
}

function getPm2List() {
  try {
    const out = execFileSync(PM2, ['jlist'], { encoding: 'utf8' });
    return JSON.parse(out);
  } catch {
    return [];
  }
}

function projectView() {
  const pm2List = getPm2List();
  const byName = new Map();
  for (const proc of pm2List) {
    const name = proc?.name || proc?.pm2_env?.name;
    if (name) byName.set(name, proc);
  }

  return readProjects().map((project) => {
    const proc = byName.get(project.PM2_NAME || project.PROJECT_SLUG);
    const env = proc?.pm2_env || {};
    return {
      repo: project.REPO_REF || '',
      slug: project.PROJECT_SLUG || '',
      path: project.APP_DIR || '',
      pm2: project.PM2_NAME || '',
      port: project.APP_PORT || '',
      domain: project.APP_DOMAIN || '',
      branch: project.BRANCH || '',
      https: project.APP_HTTPS || '',
      kind: project.START_KIND || '',
      type: project.APP_TYPE || '',
      packageManager: project.PACKAGE_MANAGER || '',
      protected: Boolean(project.protected),
      status: env.status || 'stopped',
      restarts: env.restart_time ?? proc?.pm2_env?.restart_time ?? 0,
      uptime: proc?.pm2_env?.pm_uptime || 0,
      scriptPath: env.pm_exec_path || '',
      outLog: env.pm_out_log_path || '',
      errLog: env.pm_err_log_path || '',
      nodeEnv: env.node_env || '',
      memory: proc?.monit?.memory ?? proc?.pm2_env?.monit?.memory ?? 0,
      cpu: proc?.monit?.cpu ?? proc?.pm2_env?.monit?.cpu ?? 0,
    };
  });
}

function runProjectCtl(args, input = null) {
  const res = spawnSync(PROJECTCTL, args, {
    encoding: 'utf8',
    input: input ?? undefined,
    timeout: 30 * 60 * 1000,
    maxBuffer: 20 * 1024 * 1024,
  });
  if (res.error) throw res.error;
  if (res.status !== 0) {
    throw new Error((res.stderr || res.stdout || `projectctl ${args.join(' ')}`).trim());
  }
  return (res.stdout || '').trim();
}

function formatBytes(bytes) {
  const value = Number(bytes || 0);
  if (!Number.isFinite(value) || value <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let size = value;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return `${size >= 10 || unit === 0 ? size.toFixed(0) : size.toFixed(1)} ${units[unit]}`;
}

function getSystemStats() {
  const load = os.loadavg();
  const cores = Math.max(1, os.cpus().length);
  const total = os.totalmem();
  const free = os.freemem();
  const used = total - free;
  return {
    load1: load[0],
    load5: load[1],
    load15: load[2],
    cpuCores: cores,
    cpuLoadPercent: Math.min(999, (load[0] / cores) * 100),
    memoryTotal: total,
    memoryFree: free,
    memoryUsed: used,
    memoryPercent: (used / total) * 100,
    uptimeSeconds: os.uptime(),
  };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (chunk) => {
      body += chunk;
      if (body.length > 2 * 1024 * 1024) {
        reject(new Error('Request body too large'));
        req.destroy();
      }
    });
    req.on('end', () => {
      if (!body) return resolve({});
      try {
        resolve(JSON.parse(body));
      } catch (error) {
        reject(error);
      }
    });
    req.on('error', reject);
  });
}

function readBinaryBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      chunks.push(chunk);
      size += chunk.length;
      if (size > 20 * 1024 * 1024) {
        reject(new Error('Upload too large'));
        req.destroy();
      }
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function sendJson(res, status, data) {
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(JSON.stringify(data));
}

function sendText(res, status, text, extra = {}) {
  res.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Cache-Control': 'no-store',
    ...extra,
  });
  res.end(text);
}

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function renderPage() {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>MultiDev Manage</title>
  <style>
    :root { color-scheme: dark; }
    body { margin: 0; font-family: Inter, system-ui, sans-serif; background: radial-gradient(circle at top, #11213d 0, #08111f 50%, #05070c 100%); color: #e5eef8; }
    header, main { max-width: 1400px; margin: 0 auto; padding: 24px; }
    header { display: flex; justify-content: space-between; align-items: end; gap: 16px; }
    h1, h2 { margin: 0 0 12px; }
    .muted { color: #94a3b8; }
    .panel { background: rgba(8, 15, 29, 0.88); border: 1px solid rgba(148,163,184,0.2); border-radius: 18px; padding: 20px; box-shadow: 0 12px 40px rgba(0,0,0,0.35); }
    .grid { display: grid; gap: 16px; }
    .two { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .three { grid-template-columns: repeat(3, minmax(0, 1fr)); }
    label { display: grid; gap: 6px; font-size: 13px; color: #cbd5e1; }
    input, textarea, select { width: 100%; box-sizing: border-box; background: #0b1220; color: #e5eef8; border: 1px solid #22304a; border-radius: 10px; padding: 10px 12px; }
    textarea { min-height: 120px; resize: vertical; }
    button, .btn { background: linear-gradient(180deg, #38bdf8, #0ea5e9); color: #00111d; border: 0; border-radius: 999px; padding: 10px 14px; font-weight: 700; cursor: pointer; text-decoration: none; display: inline-flex; align-items: center; gap: 6px; }
    button.secondary, .btn.secondary { background: #162033; color: #dbeafe; border: 1px solid #2a3b59; }
    button.danger, .btn.danger { background: linear-gradient(180deg, #f87171, #ef4444); color: #1c0202; }
    button.ghost, .btn.ghost { background: transparent; color: #dbeafe; border: 1px solid #2a3b59; }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; vertical-align: top; padding: 10px; border-bottom: 1px solid rgba(148,163,184,0.16); }
    th { color: #93c5fd; font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; }
    code { background: #0b1220; padding: 2px 6px; border-radius: 6px; }
    .actions { display: flex; flex-wrap: wrap; gap: 8px; }
    .status-online { color: #4ade80; }
    .status-stopped { color: #fbbf24; }
    .status-errored { color: #f87171; }
    .status-launching { color: #38bdf8; }
    .small { font-size: 12px; color: #94a3b8; }
    .stack { display: grid; gap: 10px; }
    .sticky { position: sticky; top: 0; z-index: 5; backdrop-filter: blur(12px); }
    .space { height: 12px; }
    .pill { display: inline-flex; padding: 3px 8px; border-radius: 999px; background: #102338; border: 1px solid #23405f; font-size: 12px; }
    .table-wrap { overflow: auto; }
    .flash { margin-top: 10px; padding: 10px 12px; border-radius: 10px; background: #0b1220; border: 1px solid #22304a; white-space: pre-wrap; }
    .scripts-panel { background: #08111f; border: 1px solid #22304a; border-radius: 18px; box-shadow: 0 30px 80px rgba(0,0,0,0.35); margin: 0 24px 24px; }
    .scripts-panel header { padding: 18px 20px 0; display: flex; justify-content: space-between; align-items: center; gap: 16px; }
    .scripts-panel .body { padding: 18px 20px 20px; }
    .script-list { display: grid; gap: 10px; }
    .script-row { display: grid; grid-template-columns: 1fr auto; gap: 12px; align-items: start; padding: 12px; border: 1px solid #22304a; border-radius: 12px; background: #0b1220; }
    .script-row code { white-space: pre-wrap; }
    .kv-list { display: grid; gap: 10px; }
    .kv-item { display: grid; gap: 4px; padding: 12px; border: 1px solid #22304a; border-radius: 12px; background: #0b1220; }
    .kv-item code { white-space: pre-wrap; word-break: break-word; }
  </style>
</head>
<body>
  <header class="sticky">
    <div>
      <h1>MultiDev Manage</h1>
      <div class="muted">Projects, PM2 controls, logs, and per-domain protection from one page.</div>
      <div id="systemStats" class="small">Loading machine stats...</div>
    </div>
    <div class="actions">
      <a class="btn ghost" href="/">Portal</a>
      <a class="btn ghost" href="/phpmyadmin/">phpMyAdmin</a>
      <button class="secondary" id="refreshBtn" type="button">Refresh</button>
    </div>
  </header>
  <main class="grid" style="gap:20px">
    <section class="panel">
      <h2>New Project</h2>
      <div class="grid two">
        <label>GitHub repo
          <input id="repo" placeholder="shaykid/RepoName">
        </label>
        <label>Domain
          <input id="domain" placeholder="example.com">
        </label>
        <label>Branch
          <input id="branch" placeholder="main">
        </label>
        <label>PM2 name
          <input id="pm2Name" placeholder="repo-name">
        </label>
        <label>Port
          <input id="port" placeholder="auto">
        </label>
        <label>Entrypoint
          <input id="entrypoint" placeholder="server/index.js">
        </label>
      </div>
      <div class="space"></div>
      <div class="grid two">
        <label>Env file contents
          <textarea id="envText" placeholder="Paste .env contents here if needed"></textarea>
        </label>
        <label>Project access password
          <textarea id="accessPassword" placeholder="Optional: set a password for the project domain after install"></textarea>
        </label>
      </div>
      <div class="space"></div>
      <button id="installBtn" type="button">Install project</button>
      <div id="installResult" class="flash" hidden></div>
    </section>

    <section class="panel">
      <h2>Running Projects</h2>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Repo</th>
              <th>Domain</th>
              <th>PM2</th>
              <th>Port</th>
              <th>Memory</th>
              <th>Status</th>
              <th>Protected</th>
              <th>Branch</th>
              <th>Details</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody id="projectsBody"></tbody>
        </table>
      </div>
      <div id="listResult" class="flash" hidden></div>
    </section>
  </main>
  <div id="scriptsPanel" class="scripts-panel" hidden>
    <header>
      <div>
        <h2 id="scriptsTitle">Package Scripts</h2>
        <div id="scriptsSubtitle" class="muted"></div>
      </div>
      <button id="closeScriptsBtn" class="ghost" type="button">Close</button>
    </header>
    <div class="body">
      <div id="scriptsFlash" class="flash" hidden></div>
      <div id="scriptsList" class="script-list"></div>
    </div>
  </div>
  <div id="dbPanel" class="scripts-panel" hidden>
    <header>
      <div>
        <h2 id="dbTitle">Database Details</h2>
        <div id="dbSubtitle" class="muted"></div>
      </div>
      <button id="closeDbBtn" class="ghost" type="button">Close</button>
    </header>
    <div class="body">
      <div id="dbFlash" class="flash" hidden></div>
      <div id="dbList" class="kv-list"></div>
    </div>
  </div>
  <div id="envPanel" class="scripts-panel" hidden>
    <header>
      <div>
        <h2 id="envTitle">Environment Values</h2>
        <div id="envSubtitle" class="muted"></div>
      </div>
      <div class="actions">
        <a id="envDownloadBtn" class="btn ghost" href="#" download>Download zip</a>
        <label class="btn ghost" style="cursor:pointer">
          <input id="envUploadInput" type="file" accept=".zip" hidden>
          Choose zip
        </label>
        <button id="envUploadBtn" class="secondary" type="button">Upload zip</button>
        <button id="closeEnvBtn" class="ghost" type="button">Close</button>
      </div>
    </header>
    <div class="body">
      <div id="envFlash" class="flash" hidden></div>
      <div id="envList" class="kv-list"></div>
    </div>
  </div>
  <script>
    const API = 'api';
    const projectsBody = document.getElementById('projectsBody');
    const listResult = document.getElementById('listResult');
    const installResult = document.getElementById('installResult');
    const systemStats = document.getElementById('systemStats');
    const scriptsPanel = document.getElementById('scriptsPanel');
    const scriptsTitle = document.getElementById('scriptsTitle');
    const scriptsSubtitle = document.getElementById('scriptsSubtitle');
    const scriptsList = document.getElementById('scriptsList');
    const scriptsFlash = document.getElementById('scriptsFlash');
    const closeScriptsBtn = document.getElementById('closeScriptsBtn');
    const dbPanel = document.getElementById('dbPanel');
    const dbTitle = document.getElementById('dbTitle');
    const dbSubtitle = document.getElementById('dbSubtitle');
    const dbList = document.getElementById('dbList');
    const dbFlash = document.getElementById('dbFlash');
    const closeDbBtn = document.getElementById('closeDbBtn');
    const envPanel = document.getElementById('envPanel');
    const envTitle = document.getElementById('envTitle');
    const envSubtitle = document.getElementById('envSubtitle');
    const envList = document.getElementById('envList');
    const envFlash = document.getElementById('envFlash');
    const envDownloadBtn = document.getElementById('envDownloadBtn');
    const envUploadInput = document.getElementById('envUploadInput');
    const envUploadBtn = document.getElementById('envUploadBtn');
    const closeEnvBtn = document.getElementById('closeEnvBtn');
    let currentScriptsRef = '';
    let currentDbRef = '';
    let currentEnvRef = '';

    function showMessage(el, value, ok = true) {
      el.hidden = false;
      el.style.borderColor = ok ? '#1d4ed8' : '#7f1d1d';
      el.textContent = value;
    }

    function fmtTime(ms) {
      if (!ms) return 'n/a';
      const diff = Date.now() - Number(ms);
      if (!Number.isFinite(diff) || diff < 0) return 'n/a';
      const sec = Math.floor(diff / 1000);
      if (sec < 60) return sec + 's';
      const min = Math.floor(sec / 60);
      if (min < 60) return min + 'm';
      const hrs = Math.floor(min / 60);
      if (hrs < 24) return hrs + 'h';
      return Math.floor(hrs / 24) + 'd';
    }

    function refreshSystemStats(stats) {
      if (!stats) {
        systemStats.textContent = 'Machine stats unavailable';
        return;
      }
      const cpuLoad = Number(stats.cpuLoadPercent || 0).toFixed(1) + '%';
      const memory = formatBytes(stats.memoryUsed || 0) + ' / ' + formatBytes(stats.memoryTotal || 0) + ' (' + Number(stats.memoryPercent || 0).toFixed(1) + '%)';
      systemStats.textContent = 'CPU load: ' + Number(stats.load1 || 0).toFixed(2) + ' (' + cpuLoad + ') · Memory: ' + memory;
    }

    async function api(path, options = {}) {
      const res = await fetch(\`\${API}\${path}\`, {
        headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
        credentials: 'same-origin',
        ...options,
      });
      const text = await res.text();
      let data;
      try { data = text ? JSON.parse(text) : null; } catch { data = text; }
      if (!res.ok) {
        const message = data && typeof data === 'object' ? (data.error || data.message || text) : text;
        throw new Error(message || \`Request failed: \${res.status}\`);
      }
      return data;
    }

    async function refresh() {
      const [dataResult, statsResult] = await Promise.allSettled([
        api('/projects'),
        api('/system'),
      ]);
      if (dataResult.status !== 'fulfilled') throw dataResult.reason;
      const data = dataResult.value;
      renderProjects(data.projects || []);
      refreshSystemStats(statsResult.status === 'fulfilled' ? statsResult.value.system || null : null);
    }

    function statusClass(status) {
      const value = String(status || '').toLowerCase();
      if (value.includes('online')) return 'status-online';
      if (value.includes('launch')) return 'status-launching';
      if (value.includes('error')) return 'status-errored';
      return 'status-stopped';
    }

    function rowActions(project) {
      const ref = encodeURIComponent(project.repo);
      const logOut = \`\${API}/projects/\${ref}/logs?type=out&download=1\`;
      const logErr = \`\${API}/projects/\${ref}/logs?type=error&download=1\`;
      return \`
        <div class="actions">
          <button class="secondary" data-action="update" data-ref="\${ref}">Pull</button>
          <button class="secondary" data-action="restart" data-ref="\${ref}">Restart</button>
          <button class="secondary" data-action="stop" data-ref="\${ref}">Stop</button>
          <button class="danger" data-action="uninstall" data-ref="\${ref}">Kill</button>
          <button class="secondary" data-action="db" data-ref="\${ref}">DB</button>
          <button class="secondary" data-action="env" data-ref="\${ref}">Env</button>
          <button class="secondary" data-action="scripts" data-ref="\${ref}">Scripts</button>
          <a class="btn ghost" href="\${logOut}">Out log</a>
          <a class="btn ghost" href="\${logErr}">Err log</a>
          <span class="pill">\${project.protected ? 'protected' : 'open'}</span>
        </div>
        <div class="space"></div>
        <div class="stack">
          <input data-password-for="\${ref}" type="password" placeholder="Project password">
          <div class="actions">
            <button class="secondary" data-action="protect" data-ref="\${ref}">Set password</button>
            <button class="ghost" data-action="clear-password" data-ref="\${ref}">Clear password</button>
          </div>
        </div>
      \`;
    }

    function renderProjects(projects) {
      if (!projects.length) {
        projectsBody.innerHTML = '<tr><td colspan="10" class="muted">No projects found.</td></tr>';
        return;
      }
      projectsBody.innerHTML = projects.map((project) => \`
        <tr>
          <td>
            <div><strong>\${escapeHtml(project.repo || project.slug || '')}</strong></div>
            <div class="small">\${escapeHtml(project.path || '')}</div>
          </td>
          <td>
            <div>\${project.domain ? \`<a href="https://\${escapeHtml(project.domain)}/" target="_blank" rel="noreferrer">\${escapeHtml(project.domain)}</a>\` : '<span class="muted">n/a</span>'}</div>
            <div class="small">\${project.https === 'yes' ? 'HTTPS' : 'HTTP only'}</div>
          </td>
          <td>
            <div><code>\${escapeHtml(project.pm2 || '')}</code></div>
            <div class="small">\${escapeHtml(project.scriptPath || '')}</div>
          </td>
          <td>\${escapeHtml(project.port || '')}</td>
          <td>\${escapeHtml(formatBytes(project.memory || 0))}</td>
          <td><span class="\${statusClass(project.status)}">\${escapeHtml(project.status || '')}</span></td>
          <td>\${project.protected ? 'yes' : 'no'}</td>
          <td>\${escapeHtml(project.branch || '')}</td>
          <td class="small">
            kind: \${escapeHtml(project.kind || '')}<br>
            type: \${escapeHtml(project.type || '')}<br>
            pm: \${escapeHtml(project.packageManager || '')}<br>
            restarts: \${escapeHtml(String(project.restarts ?? 0))}<br>
            uptime: \${escapeHtml(fmtTime(project.uptime))}<br>
            env: \${escapeHtml(project.nodeEnv || '')}
          </td>
          <td>\${rowActions(project)}</td>
        </tr>
      \`).join('');
    }

    function openScriptsModal(ref, scripts, subtitle) {
      currentScriptsRef = ref;
      scriptsTitle.textContent = 'Package Scripts';
      scriptsSubtitle.textContent = subtitle || '';
      scriptsFlash.hidden = true;
      scriptsList.innerHTML = scripts.length
        ? scripts.map((script) => \`
          <div class="script-row">
            <div>
              <div><strong>\${escapeHtml(script.name || '')}</strong></div>
              <div class="small"><code>\${escapeHtml(script.command || '')}</code></div>
            </div>
            <div class="actions">
              <button class="secondary" data-script-run="\${escapeHtml(script.name || '')}" type="button">Run</button>
              <button class="ghost" data-script-activate="\${escapeHtml(script.name || '')}" type="button">Activate in PM2</button>
            </div>
          </div>
        \`).join('')
        : '<div class="muted">No package scripts found.</div>';
      scriptsPanel.hidden = false;
      scriptsPanel.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }

    function closeScriptsModal() {
      scriptsPanel.hidden = true;
      currentScriptsRef = '';
      scriptsList.innerHTML = '';
      scriptsFlash.hidden = true;
    }

    function openDbPanel(ref, details, subtitle) {
      currentDbRef = ref;
      dbTitle.textContent = 'Database Details';
      dbSubtitle.textContent = subtitle || '';
      dbFlash.hidden = true;
      const rows = [
        ['DB supplier', details.DB_SUPPLIER || 'n/a'],
        ['Database name', details.DB_NAME || details.DB_DATABASE || details.MYSQL_DATABASE || details.POSTGRES_DB || 'n/a'],
        ['Database user', details.DB_USER || details.MYSQL_USER || details.POSTGRES_USER || 'n/a'],
        ['Database password', details.DB_PASSWORD || details.MYSQL_PASSWORD || details.POSTGRES_PASSWORD || 'n/a'],
        ['Database host', details.DB_HOST || details.MYSQL_HOST || details.POSTGRES_HOST || 'n/a'],
        ['Database port', details.DB_PORT || details.MYSQL_PORT || details.POSTGRES_PORT || 'n/a'],
        ['DATABASE_URL', details.DATABASE_URL || 'n/a'],
      ];
      const sourceFiles = (details.files || []).map((file) => escapeHtml(file)).join('<br>');
      dbList.innerHTML = \`
        \${rows.map(([label, value]) => \`
          <div class="kv-item">
            <div class="small">\${escapeHtml(label)}</div>
            <code>\${escapeHtml(value)}</code>
          </div>
        \`).join('')}
        <div class="kv-item">
          <div class="small">Source files</div>
          <div class="small">\${sourceFiles || 'n/a'}</div>
        </div>
      \`;
      dbPanel.hidden = false;
      dbPanel.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }

    function closeDbPanel() {
      dbPanel.hidden = true;
      currentDbRef = '';
      dbList.innerHTML = '';
      dbFlash.hidden = true;
    }

    function renderKeyValueList(listEl, entries) {
      listEl.innerHTML = entries.length
        ? entries.map(([label, value]) => \`
          <div class="kv-item">
            <div class="small">\${escapeHtml(label)}</div>
            <code>\${escapeHtml(value)}</code>
          </div>
        \`).join('')
        : '<div class="muted">No values found.</div>';
    }

    function openEnvPanel(ref, details, subtitle) {
      currentEnvRef = ref;
      envTitle.textContent = 'Environment Values';
      envSubtitle.textContent = subtitle || '';
      envFlash.hidden = true;
      const entries = Object.entries(details.env || {})
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([key, value]) => [key, String(value)]);
      renderKeyValueList(envList, entries);
      envDownloadBtn.href = \`\${API}/projects/\${ref}/env/download\`;
      envPanel.hidden = false;
      envPanel.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }

    function closeEnvPanel() {
      envPanel.hidden = true;
      currentEnvRef = '';
      envList.innerHTML = '';
      envFlash.hidden = true;
      envUploadInput.value = '';
    }

    async function loadScripts(ref) {
      const data = await api(\`/projects/\${ref}/scripts\`);
      openScriptsModal(ref, data.scripts || [], data.project || ref);
    }

    async function loadDb(ref) {
      const data = await api(\`/projects/\${ref}/db\`);
      openDbPanel(ref, data.db || {}, data.project || ref);
    }

    async function loadEnv(ref) {
      const data = await api(\`/projects/\${ref}/env\`);
      openEnvPanel(ref, data, data.project || ref);
    }

    async function uploadEnv(ref, file) {
      const res = await fetch(\`\${API}/projects/\${ref}/env/upload\`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/zip' },
        credentials: 'same-origin',
        body: file,
      });
      const text = await res.text();
      let data;
      try { data = text ? JSON.parse(text) : null; } catch { data = text; }
      if (!res.ok) {
        const message = data && typeof data === 'object' ? (data.error || data.message || text) : text;
        throw new Error(message || \`Upload failed: \${res.status}\`);
      }
      showMessage(envFlash, data.message || 'Environment files uploaded');
      await refresh();
    }

    async function runScript(ref, script, mode) {
      const action = mode === 'activate' ? 'activate' : 'run';
      const res = await api(\`/projects/\${ref}/scripts/\${action}\`, {
        method: 'POST',
        body: JSON.stringify({ script }),
      });
      showMessage(scriptsFlash, res.message || 'Done');
      await refresh();
    }

    async function handleAction(action, ref) {
      const passwordInput = document.querySelector(\`[data-password-for="\${ref}"]\`);
      const password = passwordInput ? passwordInput.value : '';
      const res = await api(\`/projects/\${ref}/\${action}\`, {
        method: 'POST',
        body: JSON.stringify(action === 'protect'
          ? { password }
          : action === 'clear-password'
            ? { clear: true }
            : {}
        ),
      });
      showMessage(listResult, res.message || 'Done');
      await refresh();
    }

    document.addEventListener('click', async (event) => {
      const btn = event.target.closest('button[data-action]');
      if (!btn) return;
      const action = btn.dataset.action;
      const ref = btn.dataset.ref;
      if (!action || !ref) return;
      if (action === 'scripts') {
        btn.disabled = true;
        try {
          await loadScripts(ref);
        } catch (error) {
          showMessage(listResult, error.message, false);
        } finally {
          btn.disabled = false;
        }
        return;
      }
      btn.disabled = true;
      try {
        await handleAction(action, ref);
      } catch (error) {
        showMessage(listResult, error.message, false);
      } finally {
        btn.disabled = false;
      }
    });

    document.getElementById('refreshBtn').addEventListener('click', async () => {
      try { await refresh(); } catch (error) { showMessage(listResult, error.message, false); }
    });

    closeScriptsBtn.addEventListener('click', closeScriptsModal);
    closeDbBtn.addEventListener('click', closeDbPanel);
    closeEnvBtn.addEventListener('click', closeEnvPanel);
    document.addEventListener('click', async (event) => {
      const btn = event.target.closest('button[data-script-run], button[data-script-activate]');
      if (!btn || !currentScriptsRef) return;
      const script = btn.dataset.scriptRun || btn.dataset.scriptActivate;
      if (!script) return;
      const mode = btn.dataset.scriptActivate ? 'activate' : 'run';
      btn.disabled = true;
      try {
        await runScript(currentScriptsRef, script, mode);
      } catch (error) {
        showMessage(scriptsFlash, error.message, false);
      } finally {
        btn.disabled = false;
      }
    });

    document.addEventListener('click', async (event) => {
      const btn = event.target.closest('button[data-action="db"]');
      if (!btn) return;
      const ref = btn.dataset.ref;
      if (!ref) return;
      btn.disabled = true;
      try {
        await loadDb(ref);
      } catch (error) {
        showMessage(dbFlash, error.message, false);
        dbPanel.hidden = false;
      } finally {
        btn.disabled = false;
      }
    });

    document.addEventListener('click', async (event) => {
      const btn = event.target.closest('button[data-action="env"]');
      if (!btn) return;
      const ref = btn.dataset.ref;
      if (!ref) return;
      btn.disabled = true;
      try {
        await loadEnv(ref);
      } catch (error) {
        showMessage(envFlash, error.message, false);
        envPanel.hidden = false;
      } finally {
        btn.disabled = false;
      }
    });

    envUploadBtn.addEventListener('click', async () => {
      if (!currentEnvRef) return;
      const file = envUploadInput.files && envUploadInput.files[0];
      if (!file) {
        showMessage(envFlash, 'Choose a zip file first.', false);
        envPanel.hidden = false;
        return;
      }
      envUploadBtn.disabled = true;
      try {
        await uploadEnv(currentEnvRef, file);
      } catch (error) {
        showMessage(envFlash, error.message, false);
        envPanel.hidden = false;
      } finally {
        envUploadBtn.disabled = false;
      }
    });

    document.getElementById('installBtn').addEventListener('click', async () => {
      const payload = {
        repo: document.getElementById('repo').value.trim(),
        domain: document.getElementById('domain').value.trim(),
        branch: document.getElementById('branch').value.trim(),
        pm2Name: document.getElementById('pm2Name').value.trim(),
        port: document.getElementById('port').value.trim(),
        entrypoint: document.getElementById('entrypoint').value.trim(),
        envText: document.getElementById('envText').value,
        accessPassword: document.getElementById('accessPassword').value,
      };
      try {
        const result = await api('/projects', {
          method: 'POST',
          body: JSON.stringify(payload),
        });
        showMessage(installResult, result.message || 'Installed');
        await refresh();
      } catch (error) {
        showMessage(installResult, error.message, false);
      }
    });

    function escapeHtml(value) {
      return String(value ?? '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
    }

    refresh().catch((error) => showMessage(listResult, error.message, false));
    setInterval(async () => {
      try {
        const data = await api('/system');
        refreshSystemStats(data.system || null);
      } catch {
        // Ignore transient stats failures.
      }
    }, 15000);
  </script>
</body>
</html>`;
}

function basicAuth(req, res) {
  const header = req.headers.authorization || '';
  if (!header.startsWith('Basic ')) return false;
  const decoded = Buffer.from(header.slice(6), 'base64').toString('utf8');
  const colon = decoded.indexOf(':');
  if (colon === -1) return false;
  const user = decoded.slice(0, colon);
  const pass = decoded.slice(colon + 1);
  return user === BASIC_USER && pass === (process.env.MANAGE_PASSWORD || PASSWORD);
}

function requireAuth(req, res) {
  if (basicAuth(req, res)) return true;
  res.writeHead(401, {
    'WWW-Authenticate': 'Basic realm="MultiDev Manage"',
    'Content-Type': 'text/plain; charset=utf-8',
  });
  res.end('Authentication required');
  return false;
}

function logTail(filePath, lines = 200) {
  if (!filePath || !fs.existsSync(filePath)) return '';
  const content = fs.readFileSync(filePath, 'utf8');
  const split = content.split(/\r?\n/);
  return split.slice(Math.max(0, split.length - lines)).join('\n');
}

async function handleRequest(req, res) {
  if (!requireAuth(req, res)) return;

  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const pathname = url.pathname.replace(/\/+$/, '') || '/';

  try {
    if (req.method === 'GET' && (pathname === '/' || pathname === '/manage')) {
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store',
      });
      res.end(renderPage());
      return;
    }

    if (req.method === 'GET' && pathname === '/api/projects') {
      sendJson(res, 200, { projects: projectView() });
      return;
    }

    if (req.method === 'GET' && pathname === '/api/system') {
      sendJson(res, 200, { system: getSystemStats() });
      return;
    }

    if (req.method === 'POST' && pathname === '/api/projects') {
      const body = await readBody(req);
      const repo = repoRefFromArg(body.repo || '');
      const args = ['install'];
      if (body.domain) args.push('--domain', String(body.domain).trim());
      if (body.branch) args.push('--branch', String(body.branch).trim());
      if (body.pm2Name) args.push('--pm2-name', String(body.pm2Name).trim());
      if (body.port) args.push('--port', String(body.port).trim());
      if (body.entrypoint) args.push('--entrypoint', String(body.entrypoint).trim());
      let tempEnv = '';
      if (body.envText && String(body.envText).trim()) {
        const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vps-manage-'));
        tempEnv = path.join(tmpDir, 'project.env');
        fs.writeFileSync(tempEnv, String(body.envText).replace(/\r\n/g, '\n'));
        fs.chmodSync(tempEnv, 0o600);
        args.push('--env-file', tempEnv);
      }
      args.push(repo);
      const output = runProjectCtl(args);
      if (tempEnv) {
        fs.rmSync(path.dirname(tempEnv), { recursive: true, force: true });
      }
      if (body.accessPassword && String(body.accessPassword).trim()) {
        runProjectCtl(['password', '--password', String(body.accessPassword).trim(), repo]);
      }
      sendJson(res, 200, { ok: true, message: output || 'Installed project' });
      return;
    }

    const dbMatch = pathname.match(/^\/api\/projects\/(.+?)\/db$/);
    if (dbMatch) {
      const ref = decodeURIComponent(dbMatch[1]);
      const meta = parseEnvFile(metaPathForRef(ref));
      const { files, db } = pickDbDetails(meta.APP_DIR || '');
      sendJson(res, 200, {
        project: meta.APP_DOMAIN || meta.PROJECT_SLUG || ref,
        files,
        db,
      });
      return;
    }

    const envMatch = pathname.match(/^\/api\/projects\/(.+?)\/env(?:\/(download|upload))?$/);
    if (envMatch) {
      const ref = decodeURIComponent(envMatch[1]);
      const mode = envMatch[2] || '';
      const meta = parseEnvFile(metaPathForRef(ref));
      const projectPath = meta.APP_DIR || '';
      const { files, env } = pickEnvDetails(projectPath);

      if (req.method === 'GET' && !mode) {
        sendJson(res, 200, {
          project: meta.APP_DOMAIN || meta.PROJECT_SLUG || ref,
          files,
          env,
        });
        return;
      }

      if ((req.method === 'GET' || req.method === 'HEAD') && mode === 'download') {
        const zipBuffer = createEnvZip(projectPath);
        res.writeHead(200, {
          'Content-Type': 'application/zip',
          'Content-Disposition': `attachment; filename="${slugFromRef(ref)}-env.zip"`,
        });
        if (req.method === 'HEAD') {
          res.end();
          return;
        }
        res.end(zipBuffer);
        return;
      }

      if (req.method === 'POST' && mode === 'upload') {
        const body = await readBinaryBody(req);
        if (!body || !body.length) {
          throw new Error('Missing zip upload body');
        }
        replaceEnvZip(projectPath, body);
        sendJson(res, 200, { ok: true, message: `Environment files updated for ${ref}` });
        return;
      }
    }

    const scriptsMatch = pathname.match(/^\/api\/projects\/(.+?)\/scripts(?:\/(run|activate))?$/);
    if (scriptsMatch) {
      const ref = decodeURIComponent(scriptsMatch[1]);
      const scriptAction = scriptsMatch[2] || '';
      const meta = parseEnvFile(metaPathForRef(ref));
      const scripts = readPackageScripts(meta.APP_DIR || '');

      if (req.method === 'GET' && !scriptAction) {
        sendJson(res, 200, {
          project: meta.APP_DOMAIN || meta.PROJECT_SLUG || ref,
          scripts,
        });
        return;
      }

      if (req.method === 'POST' && scriptAction) {
        const body = await readBody(req);
        const script = String(body.script || '').trim();
        if (!script) {
          throw new Error('Missing script name');
        }
        if (scriptAction === 'activate') {
          const output = runProjectCtl(['script', '--pm2', ref, script]);
          sendJson(res, 200, { ok: true, message: output || `Activated ${script}` });
        } else {
          const output = runProjectCtl(['script', ref, script]);
          sendJson(res, 200, { ok: true, message: output || `Ran ${script}` });
        }
        return;
      }
    }

    const actionMatch = pathname.match(/^\/api\/projects\/(.+?)\/(restart|update|stop|uninstall|password|logs)$/);
    if (actionMatch) {
      const ref = decodeURIComponent(actionMatch[1]);
      const action = actionMatch[2];

      if (action === 'logs') {
        const meta = parseEnvFile(metaPathForRef(ref));
        const pm2Name = meta.PM2_NAME || slugFromRef(ref);
        const target = getPm2List().find((proc) => (proc?.name || proc?.pm2_env?.name) === pm2Name);
        const lines = Math.min(Number(url.searchParams.get('lines') || 200), 4000);
        const stream = url.searchParams.get('type') || 'out';
        const logFile = stream === 'error'
          ? target?.pm2_env?.pm_err_log_path
          : target?.pm2_env?.pm_out_log_path;
        const content = logTail(logFile, lines) || '';
        const download = url.searchParams.get('download') === '1';
        sendText(res, 200, content || `(no log data for ${ref})\n`, download ? {
          'Content-Disposition': `attachment; filename="${slugFromRef(ref)}-${stream}.log"`,
        } : {});
        return;
      }

      const body = req.method === 'POST' ? await readBody(req) : {};
      if (action === 'password') {
        if (body.clear) {
          runProjectCtl(['password', '--clear', ref]);
        } else {
          runProjectCtl(['password', '--password', String(body.password || '').trim(), ref]);
        }
      } else {
        runProjectCtl([action, ref]);
      }

      sendJson(res, 200, { ok: true, message: `${action} complete for ${ref}` });
      return;
    }

    res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ error: 'Not found' }));
  } catch (error) {
    const status = error.statusCode || 500;
    sendJson(res, status, { error: error.message || String(error) });
  }
}

const server = http.createServer((req, res) => {
  handleRequest(req, res).catch((error) => {
    sendJson(res, 500, { error: error.message || String(error) });
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`manage server listening on 127.0.0.1:${PORT}`);
});
