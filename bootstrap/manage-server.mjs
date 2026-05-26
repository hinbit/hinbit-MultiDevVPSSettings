#!/usr/bin/env node
import fs from 'fs';
import path from 'path';
import http from 'http';
import { execFileSync, spawn, spawnSync } from 'child_process';
import os from 'os';
import { fileURLToPath } from 'url';

const META_DIR = '/etc/vps-projects';
const AUTH_DIR = '/etc/nginx/project-auth';
const SYSTEM_ENV_FILE = '/etc/vps-system.env';
const DB_MACHINES_FILE = '/etc/vps-db-machines.json';
const SSH_KEYS_FILE = '/etc/vps-ssh-keys.json';
const SSH_KEYS_DIR = '/root/.ssh/vps-managed-keys';
const PROJECTCTL = '/usr/local/bin/projectctl';
const PM2 = 'pm2';
const BASIC_USER = 'manage';
const PORT = Number(process.env.MANAGE_PORT || 8090);
const PASSWORD = process.env.MANAGE_PASSWORD || '';
const LOCAL_DB_MACHINE_ID = 'local-current';
const LOCAL_DB_MACHINE = {
  id: LOCAL_DB_MACHINE_ID,
  name: 'localhost (current)',
  host: '127.0.0.1',
  rootUser: 'root',
  rootPassword: '',
  port: '3306',
  notes: 'Current VPS local DB on this VPS',
};
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

function readProjectDiskUsage(projectPath) {
  if (!projectPath || !fs.existsSync(projectPath)) return 0;
  try {
    const out = execFileSync('du', ['-s', '-B1', projectPath], { encoding: 'utf8' }).trim();
    const size = Number.parseInt(out.split(/\s+/)[0], 10);
    return Number.isFinite(size) && size > 0 ? size : 0;
  } catch {
    return 0;
  }
}

function readProjectSslStatus(project) {
  const domain = String(project?.APP_DOMAIN || '').trim();
  const https = String(project?.APP_HTTPS || '').toLowerCase();
  if (!domain) {
    return { label: 'no domain', className: 'neutral', active: false };
  }
  if (https !== 'yes') {
    return { label: 'HTTP only', className: 'warn', active: false };
  }

  const confPath = `/etc/nginx/sites-available/${domain}.conf`;
  const certPath = `/etc/letsencrypt/live/${domain}/fullchain.pem`;
  const certReady = fs.existsSync(certPath) && fs.statSync(certPath).size > 0;
  const confReady = fs.existsSync(confPath) && /listen\s+443\s+ssl/.test(fs.readFileSync(confPath, 'utf8'));

  if (certReady && confReady) {
    return { label: 'SSL active', className: 'good', active: true };
  }
  if (certReady || confReady) {
    return { label: 'SSL pending', className: 'warn', active: false };
  }
  return { label: 'SSL missing', className: 'warn', active: false };
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

function mysqlExecForMachine(machineId, query) {
  const machines = readDbMachines();
  const machine = machines.find((item) => String(item.id) === String(machineId)) || machines.find((item) => String(item.id) === LOCAL_DB_MACHINE_ID) || LOCAL_DB_MACHINE;
  const host = String(machine.host || '127.0.0.1').trim();
  const port = String(machine.port || '3306').trim() || '3306';
  const user = String(machine.rootUser || 'root').trim() || 'root';
  const password = String(machine.rootPassword || '').trim();
  if (!password && (host === 'localhost' || host === '127.0.0.1' || host === '::1')) {
    return execFileSync(
      'mysql',
      ['--protocol=socket', '-uroot', '--batch', '--skip-column-names', '-e', query],
      { encoding: 'utf8' },
    );
  }
  return execFileSync(
    'mysql',
    ['--protocol=tcp', '-h', host, '-P', port, '-u', user, '--batch', '--skip-column-names', '-e', query],
    {
      encoding: 'utf8',
      env: { ...process.env, MYSQL_PWD: password },
    },
  );
}

function readMysqlAccounts(dbUser, machineId = LOCAL_DB_MACHINE_ID) {
  if (!dbUser) return [];
  try {
    const out = mysqlExecForMachine(machineId, `SELECT CONCAT(User, '@', Host) FROM mysql.user WHERE User='${String(dbUser).replace(/'/g, "''")}' ORDER BY Host;`);
    return out.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  } catch {
    return [];
  }
}

function readDbMachines() {
  try {
    if (!fs.existsSync(DB_MACHINES_FILE)) return [];
    const data = JSON.parse(fs.readFileSync(DB_MACHINES_FILE, 'utf8'));
    if (!Array.isArray(data)) return [];
    const machines = data.map((machine, index) => ({
      id: String(machine.id || `${Date.now().toString(36)}-${index}`),
      name: String(machine.name || machine.label || '').trim(),
      host: String(machine.host || '').trim(),
      rootUser: String(machine.rootUser || machine.user || '').trim(),
      rootPassword: String(machine.rootPassword || machine.password || '').trim(),
      port: String(machine.port || '3306').trim() || '3306',
      notes: String(machine.notes || '').trim(),
    })).filter((machine) => machine.name || machine.host || machine.rootUser || machine.rootPassword);
    if (!machines.some((machine) => machine.id === LOCAL_DB_MACHINE_ID)) {
      machines.unshift({ ...LOCAL_DB_MACHINE });
    }
    return machines;
  } catch {
    return [{ ...LOCAL_DB_MACHINE }];
  }
}

function writeDbMachines(machines) {
  const list = Array.isArray(machines) ? machines.slice() : [];
  if (!list.some((machine) => machine.id === LOCAL_DB_MACHINE_ID)) {
    list.unshift({ ...LOCAL_DB_MACHINE });
  }
  fs.writeFileSync(DB_MACHINES_FILE, `${JSON.stringify(list, null, 2)}\n`);
  fs.chmodSync(DB_MACHINES_FILE, 0o600);
}

function readSshKeyRegistry() {
  try {
    if (!fs.existsSync(SSH_KEYS_FILE)) return [];
    const data = JSON.parse(fs.readFileSync(SSH_KEYS_FILE, 'utf8'));
    if (!Array.isArray(data)) return [];
    return data.map((item) => ({
      id: String(item.id || item.path || '').trim(),
      name: String(item.name || path.basename(String(item.path || '')) || '').trim(),
      memo: String(item.memo || '').trim(),
      path: String(item.path || item.id || '').trim(),
      createdAt: Number(item.createdAt || 0) || 0,
      updatedAt: Number(item.updatedAt || item.createdAt || 0) || 0,
    })).filter((item) => item.path);
  } catch {
    return [];
  }
}

function writeSshKeyRegistry(records) {
  const list = Array.isArray(records) ? records.slice() : [];
  fs.writeFileSync(SSH_KEYS_FILE, `${JSON.stringify(list, null, 2)}\n`);
  fs.chmodSync(SSH_KEYS_FILE, 0o600);
}

function normalizeSshKeyName(name) {
  return String(name || '')
    .trim()
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 48);
}

function ensureSshKeysDir() {
  fs.mkdirSync(SSH_KEYS_DIR, { recursive: true, mode: 0o700 });
}

function isSshKeyCandidate(name) {
  const lower = String(name || '').toLowerCase();
  if (!name || lower.endsWith('.pub')) return false;
  if (['authorized_keys', 'known_hosts', 'known_hosts.old', 'config'].includes(lower)) return false;
  if (lower.endsWith('.json') || lower.endsWith('.log') || lower.endsWith('.txt')) return false;
  return true;
}

function readSshKeyFingerprint(pubPath) {
  try {
    return execFileSync('ssh-keygen', ['-lf', pubPath], { encoding: 'utf8' }).trim();
  } catch {
    return '';
  }
}

function scanSshKeyFiles() {
  const candidates = new Map();
  const dirs = ['/root/.ssh', SSH_KEYS_DIR];
  for (const dir of dirs) {
    if (!fs.existsSync(dir)) continue;
    for (const name of fs.readdirSync(dir)) {
      if (!isSshKeyCandidate(name)) continue;
      const privatePath = path.join(dir, name);
      const publicPath = `${privatePath}.pub`;
      if (!fs.existsSync(privatePath) || !fs.existsSync(publicPath)) continue;
      try {
        const stat = fs.statSync(privatePath);
        candidates.set(privatePath, {
          path: privatePath,
          publicPath,
          name,
          createdAt: stat.birthtimeMs || stat.mtimeMs || 0,
          updatedAt: stat.mtimeMs || 0,
        });
      } catch {
        // Ignore unreadable keys.
      }
    }
  }
  return Array.from(candidates.values()).sort((a, b) => a.name.localeCompare(b.name));
}

function readSshKeys() {
  const registry = readSshKeyRegistry();
  const registryMap = new Map(registry.map((item) => [item.path, item]));
  return scanSshKeyFiles().map((item) => {
    const reg = registryMap.get(item.path) || {};
    let publicKey = '';
    try {
      publicKey = fs.readFileSync(item.publicPath, 'utf8').trim();
    } catch {
      publicKey = '';
    }
    return {
      id: item.path,
      name: reg.name || item.name,
      memo: reg.memo || '',
      path: item.path,
      publicPath: item.publicPath,
      publicKey,
      fingerprint: readSshKeyFingerprint(item.publicPath),
      createdAt: reg.createdAt || item.createdAt || 0,
      updatedAt: reg.updatedAt || item.updatedAt || 0,
    };
  });
}

function saveSshKeyMemo(payload) {
  const pathId = String(payload?.id || '').trim();
  if (!pathId) throw new Error('Missing SSH key id');
  const memo = String(payload?.memo || '').trim();
  const name = String(payload?.name || '').trim();
  const records = readSshKeyRegistry();
  const existingIndex = records.findIndex((item) => item.path === pathId);
  const existing = existingIndex >= 0 ? records[existingIndex] : {};
  const next = {
    id: pathId,
    path: pathId,
    name: name || existing.name || path.basename(pathId),
    memo,
    createdAt: existing.createdAt || Date.now(),
    updatedAt: Date.now(),
  };
  if (existingIndex >= 0) records[existingIndex] = next;
  else records.push(next);
  writeSshKeyRegistry(records);
  return next;
}

function createSshKey(payload) {
  ensureSshKeysDir();
  const rawName = normalizeSshKeyName(payload?.name || 'github-key') || 'github-key';
  const memo = String(payload?.memo || '').trim();
  const comment = memo || rawName;
  let base = path.join(SSH_KEYS_DIR, rawName);
  let keyPath = base;
  let suffix = 0;
  while (fs.existsSync(keyPath) || fs.existsSync(`${keyPath}.pub`)) {
    suffix += 1;
    keyPath = `${base}-${suffix}`;
  }
  execFileSync('ssh-keygen', ['-t', 'ed25519', '-f', keyPath, '-N', '', '-C', comment], { stdio: 'pipe' });
  fs.chmodSync(keyPath, 0o600);
  const stat = fs.statSync(keyPath);
  const record = {
    id: keyPath,
    path: keyPath,
    name: path.basename(keyPath),
    memo,
    createdAt: stat.birthtimeMs || stat.mtimeMs || Date.now(),
    updatedAt: stat.mtimeMs || Date.now(),
  };
  const records = readSshKeyRegistry();
  records.push(record);
  writeSshKeyRegistry(records);
  return {
    ...record,
    publicPath: `${keyPath}.pub`,
    publicKey: fs.readFileSync(`${keyPath}.pub`, 'utf8').trim(),
    fingerprint: readSshKeyFingerprint(`${keyPath}.pub`),
  };
}

function normalizeDbMachine(input, existing = {}) {
  const name = String(input?.name || input?.label || existing.name || '').trim();
  const host = String(input?.host || existing.host || '').trim();
  const rootUser = String(input?.rootUser || input?.user || existing.rootUser || '').trim();
  const rootPassword = String(input?.rootPassword || input?.password || existing.rootPassword || '').trim();
  const notes = String(input?.notes || existing.notes || '').trim();
  let port = String(input?.port || existing.port || '3306').trim() || '3306';

  if (!name) throw new Error('DB machine name is required');
  if (!host) throw new Error('DB machine host is required');
  if (!rootUser) throw new Error('DB root user is required');
  if (!/^[A-Za-z0-9._:-]+$/.test(host)) throw new Error(`Invalid DB machine host: ${host}`);
  if (!/^[0-9]+$/.test(port)) {
    port = '3306';
  }
  const portNum = Number(port);
  if (!Number.isFinite(portNum) || portNum < 1 || portNum > 65535) {
    throw new Error(`Invalid DB port: ${port}`);
  }
  if (!rootPassword && !['localhost', '127.0.0.1', '::1'].includes(host)) {
    throw new Error('DB root password is required');
  }

  return {
    id: String(existing.id || input?.id || `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`),
    name,
    host,
    rootUser,
    rootPassword,
    port: String(portNum),
    notes,
  };
}

function saveDbMachine(payload) {
  const machines = readDbMachines();
  const existingIndex = machines.findIndex((machine) => machine.id === String(payload?.id || ''));
  const existing = existingIndex >= 0 ? machines[existingIndex] : {};
  const normalized = normalizeDbMachine(payload, existing);
  if (existingIndex >= 0) {
    machines[existingIndex] = normalized;
  } else {
    machines.push(normalized);
  }
  machines.sort((a, b) => String(a.name).localeCompare(String(b.name)));
  writeDbMachines(machines);
  return normalized;
}

function deleteDbMachine(id) {
  if (String(id || '') === LOCAL_DB_MACHINE_ID) {
    return;
  }
  const machines = readDbMachines();
  const next = machines.filter((machine) => machine.id !== String(id || ''));
  writeDbMachines(next);
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
    const { db } = pickDbDetails(project.APP_DIR || '');
    const disk = readProjectDiskUsage(project.APP_DIR || '');
    const ssl = readProjectSslStatus(project);
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
      mysqlAllowedIps: project.MYSQL_ALLOWED_IPS || '',
      dbMachineId: project.DB_MACHINE_ID || LOCAL_DB_MACHINE_ID,
      sshUser: project.SSH_UPLOAD_USER || '',
      sshPassword: project.SSH_UPLOAD_PASSWORD || '',
      disk,
      diskHuman: formatBytes(disk),
      dbName: db.DB_NAME || db.DB_DATABASE || db.MYSQL_DATABASE || db.POSTGRES_DB || '',
      dbUser: db.DB_USER || db.MYSQL_USER || db.POSTGRES_USER || '',
      dbPassword: db.DB_PASSWORD || db.MYSQL_PASSWORD || db.POSTGRES_PASSWORD || '',
      protected: Boolean(project.protected),
      sslActive: ssl.active,
      sslStatus: ssl.label,
      sslStatusClass: ssl.className,
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

function renderVaultRows(projects) {
  if (!projects.length) {
    return '<tr><td colspan="6" class="muted">No project database credentials found.</td></tr>';
  }
  return projects.map((project) => {
    const ref = encodeURIComponent(project.repo || project.slug || '');
    const dbName = project.dbName || 'n/a';
    const dbUser = project.dbUser || 'n/a';
    const dbPassword = project.dbPassword || 'n/a';
    const allowedIps = project.mysqlAllowedIps || 'local only';
    const copyDisabled = (!project.dbUser && !project.dbPassword && !project.mysqlAllowedIps);
    return `
      <tr>
        <td>
          <div><strong>${escapeHtml(project.repo || project.slug || '')}</strong></div>
          <div class="small">${escapeHtml(project.domain || '')}</div>
        </td>
        <td><code>${escapeHtml(dbName)}</code></td>
        <td><code>${escapeHtml(dbUser)}</code></td>
        <td><code>${escapeHtml(dbPassword)}</code></td>
        <td class="small">${escapeHtml(allowedIps)}</td>
        <td>
          <div class="copy-actions">
            <button class="secondary" type="button" data-copy-kind="user" data-ref="${ref}" ${copyDisabled ? 'disabled' : ''}>User</button>
            <button class="secondary" type="button" data-copy-kind="password" data-ref="${ref}" ${copyDisabled ? 'disabled' : ''}>Pass</button>
            <button class="ghost" type="button" data-copy-kind="all" data-ref="${ref}" ${copyDisabled ? 'disabled' : ''}>All</button>
          </div>
        </td>
      </tr>
    `;
  }).join('');
}

function renderVaultPage() {
  const projects = projectView();
  const vaultProjects = JSON.stringify(projects).replace(/</g, '\\u003c');
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>DB Vault</title>
  <style>
    :root { color-scheme: dark; }
    body { margin: 0; font-family: Inter, system-ui, sans-serif; background: radial-gradient(circle at top, #11213d 0, #08111f 50%, #05070c 100%); color: #e5eef8; padding-top: 84px; }
    header, main { max-width: 1400px; margin: 0 auto; padding: 24px; }
    header { display: flex; justify-content: space-between; align-items: end; gap: 16px; }
    h1, h2 { margin: 0 0 12px; }
    .muted { color: #94a3b8; }
    .panel { background: rgba(8, 15, 29, 0.88); border: 1px solid rgba(148,163,184,0.2); border-radius: 18px; padding: 20px; box-shadow: 0 12px 40px rgba(0,0,0,0.35); }
    .table-wrap { overflow: auto; }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; vertical-align: top; padding: 10px; border-bottom: 1px solid rgba(148,163,184,0.16); }
    th { color: #93c5fd; font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; }
    code { background: #0b1220; padding: 2px 6px; border-radius: 6px; }
    .actions { display: flex; flex-wrap: wrap; gap: 8px; }
    button, .btn { background: linear-gradient(180deg, #38bdf8, #0ea5e9); color: #00111d; border: 0; border-radius: 999px; padding: 10px 14px; font-weight: 700; cursor: pointer; text-decoration: none; display: inline-flex; align-items: center; gap: 6px; }
    button.secondary, .btn.secondary { background: #162033; color: #dbeafe; border: 1px solid #2a3b59; }
    button.ghost, .btn.ghost { background: transparent; color: #dbeafe; border: 1px solid #2a3b59; }
    button:disabled { opacity: 0.5; cursor: not-allowed; }
    .small { font-size: 12px; color: #94a3b8; }
    .copy-actions { display: flex; flex-wrap: wrap; gap: 6px; }
    .copy-actions .btn, .copy-actions button { padding: 8px 10px; font-size: 12px; }
    .flash { margin-top: 10px; padding: 10px 12px; border-radius: 10px; background: #0b1220; border: 1px solid #22304a; white-space: pre-wrap; }
    .hinbit-brand {
      position: fixed;
      top: 16px;
      left: 16px;
      z-index: 80;
      display: inline-flex;
      align-items: center;
      gap: 10px;
      padding: 10px 14px;
      border-radius: 999px;
      background: rgba(8, 15, 29, 0.82);
      border: 1px solid rgba(148,163,184,0.22);
      box-shadow: 0 12px 32px rgba(0,0,0,0.25);
      text-decoration: none;
      color: #e5eef8;
      backdrop-filter: blur(12px);
    }
    .hinbit-brand img {
      width: 22px;
      height: 22px;
      display: block;
      object-fit: contain;
    }
    .hinbit-brand span {
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.02em;
      white-space: nowrap;
    }
  </style>
</head>
<body>
  <a class="hinbit-brand" href="https://hinbit.com" target="_blank" rel="noreferrer">
    <img src="https://hinbit.com/hebrew_site/hinbit-logo-symbol.png" alt="Hinbit">
    <span>Powered by Hinbit Development</span>
  </a>
  <header>
    <div>
      <h1>DB Vault</h1>
      <div class="muted">Project database credentials with copy actions.</div>
      <div class="small">${escapeHtml(String(projects.length))} projects found</div>
    </div>
    <div class="actions">
      <a class="btn ghost" href="/manage/">Back to manage</a>
      <a class="btn ghost" href="/phpmyadmin/">phpMyAdmin</a>
      <button class="secondary" id="refreshBtn" type="button">Refresh</button>
    </div>
  </header>
  <main>
    <section class="panel">
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Project</th>
              <th>DB Name</th>
              <th>DB User</th>
              <th>DB Password</th>
              <th>Allowed IPs</th>
              <th>Copy</th>
            </tr>
          </thead>
          <tbody id="vaultBody">${renderVaultRows(projects)}</tbody>
        </table>
      </div>
      <div id="vaultResult" class="flash" hidden></div>
    </section>
  </main>
  <script>
    const vaultBody = document.getElementById('vaultBody');
    const vaultResult = document.getElementById('vaultResult');
    const refreshBtn = document.getElementById('refreshBtn');
    let currentProjects = ${vaultProjects};

    function showMessage(value, ok = true) {
      vaultResult.hidden = false;
      vaultResult.style.borderColor = ok ? '#1d4ed8' : '#7f1d1d';
      vaultResult.textContent = value;
    }

    async function copyToClipboard(text) {
      const value = String(text || '');
      if (!value) throw new Error('Nothing to copy');
      if (navigator.clipboard && navigator.clipboard.writeText) {
        await navigator.clipboard.writeText(value);
        return;
      }
      const area = document.createElement('textarea');
      area.value = value;
      area.setAttribute('readonly', 'readonly');
      area.style.position = 'fixed';
      area.style.left = '-9999px';
      document.body.appendChild(area);
      area.select();
      const ok = document.execCommand('copy');
      document.body.removeChild(area);
      if (!ok) throw new Error('Clipboard copy failed');
    }

    function getProject(ref) {
      return currentProjects.find((item) => encodeURIComponent(item.repo || item.slug || '') === ref);
    }

    async function refresh() {
      const res = await fetch('/manage/api/projects', { credentials: 'same-origin' });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Failed to load projects');
      currentProjects = data.projects || [];
      vaultBody.innerHTML = currentProjects.length
        ? currentProjects.map((project) => {
            const ref = encodeURIComponent(project.repo || project.slug || '');
            const dbName = project.dbName || 'n/a';
            const dbUser = project.dbUser || 'n/a';
            const dbPassword = project.dbPassword || 'n/a';
            const allowedIps = project.mysqlAllowedIps || 'local only';
            const copyDisabled = (!project.dbUser && !project.dbPassword && !project.mysqlAllowedIps);
            return \`
              <tr>
                <td>
                  <div><strong>\${project.repo || project.slug || ''}</strong></div>
                  <div class="small">\${project.domain || ''}</div>
                </td>
                <td><code>\${dbName}</code></td>
                <td><code>\${dbUser}</code></td>
                <td><code>\${dbPassword}</code></td>
                <td class="small">\${allowedIps}</td>
                <td>
                  <div class="copy-actions">
                    <button class="secondary" type="button" data-copy-kind="user" data-ref="\${ref}" \${copyDisabled ? 'disabled' : ''}>User</button>
                    <button class="secondary" type="button" data-copy-kind="password" data-ref="\${ref}" \${copyDisabled ? 'disabled' : ''}>Pass</button>
                    <button class="ghost" type="button" data-copy-kind="all" data-ref="\${ref}" \${copyDisabled ? 'disabled' : ''}>All</button>
                  </div>
                </td>
              </tr>
            \`;
          }).join('')
        : '<tr><td colspan="6" class="muted">No project database credentials found.</td></tr>';
    }

    document.addEventListener('click', async (event) => {
      const btn = event.target.closest('button[data-copy-kind]');
      if (!btn) return;
      const project = getProject(btn.dataset.ref || '');
      if (!project) return;
      const kind = btn.dataset.copyKind || '';
      let value = '';
      if (kind === 'user') {
        value = project.dbUser || '';
      } else if (kind === 'password') {
        value = project.dbPassword || '';
      } else {
        value = [
          'project=' + (project.repo || project.slug || ''),
          'db=' + (project.dbName || ''),
          'user=' + (project.dbUser || ''),
          'password=' + (project.dbPassword || ''),
          'allowed_ips=' + (project.mysqlAllowedIps || 'local only'),
        ].join('\\n');
      }
      btn.disabled = true;
      try {
        await copyToClipboard(value);
        showMessage(kind === 'all' ? 'Copied project DB bundle' : 'Copied ' + kind);
      } catch (error) {
        showMessage(error.message, false);
      } finally {
        btn.disabled = false;
      }
    });

    refreshBtn.addEventListener('click', async () => {
      refreshBtn.disabled = true;
      try {
        await refresh();
        showMessage('Vault refreshed');
      } catch (error) {
        showMessage(error.message, false);
      } finally {
        refreshBtn.disabled = false;
      }
    });
  </script>
</body>
</html>`;
}

function renderDbMachineRows(machines) {
  if (!machines.length) {
    return '<tr><td colspan="6" class="muted">No DB machines saved yet.</td></tr>';
  }
  return machines.map((machine) => {
    const ref = escapeHtml(machine.id || '');
    const masked = machine.rootPassword ? '••••••••' : 'n/a';
    return `
      <tr>
        <td>
          <div><strong>${escapeHtml(machine.name || '')}</strong></div>
          <div class="small">${escapeHtml(machine.notes || '')}</div>
        </td>
        <td><code>${escapeHtml(machine.host || '')}</code></td>
        <td><code>${escapeHtml(machine.rootUser || '')}</code></td>
        <td>
          <div class="password-cell">
            <code data-machine-password="${ref}">${escapeHtml(masked)}</code>
            <button class="ghost" type="button" data-machine-password-toggle="${ref}" data-secret="${escapeHtml(machine.rootPassword || '')}" aria-label="Show password">👁</button>
          </div>
        </td>
        <td><code>${escapeHtml(machine.port || '3306')}</code></td>
        <td>
          <div class="copy-actions">
            <button class="secondary" type="button" data-machine-edit="${ref}">Edit</button>
            <button class="danger" type="button" data-machine-delete="${ref}">Delete</button>
          </div>
        </td>
      </tr>
    `;
  }).join('');
}

function renderDbMachineOptions(machines, selectedId = LOCAL_DB_MACHINE_ID) {
  const list = Array.isArray(machines) && machines.length ? machines : [{ ...LOCAL_DB_MACHINE }];
  return list.map((machine) => {
    const id = String(machine.id || '');
    const label = `${machine.name || id}${machine.host ? ` · ${machine.host}` : ''}`;
    return `<option value="${escapeHtml(id)}"${id === String(selectedId || '') ? ' selected' : ''}>${escapeHtml(label)}</option>`;
  }).join('');
}

function renderDbMachinesPage() {
  const machines = readDbMachines();
  const initialMachines = JSON.stringify(machines).replace(/</g, '\\u003c');
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>DB Machines</title>
  <style>
    :root { color-scheme: dark; }
    body { margin: 0; font-family: Inter, system-ui, sans-serif; background: radial-gradient(circle at top, #11213d 0, #08111f 50%, #05070c 100%); color: #e5eef8; padding-top: 84px; }
    header, main { max-width: 1400px; margin: 0 auto; padding: 24px; }
    header { display: flex; justify-content: space-between; align-items: end; gap: 16px; }
    h1, h2 { margin: 0 0 12px; }
    .muted { color: #94a3b8; }
    .panel { background: rgba(8, 15, 29, 0.88); border: 1px solid rgba(148,163,184,0.2); border-radius: 18px; padding: 20px; box-shadow: 0 12px 40px rgba(0,0,0,0.35); }
    .grid { display: grid; gap: 16px; }
    .two { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .password-field { display: grid; gap: 6px; }
    .password-wrap { display: flex; align-items: stretch; gap: 8px; }
    .password-wrap input { flex: 1; }
    .password-wrap button { flex: 0 0 auto; min-width: 48px; padding: 10px 12px; }
    .password-cell { display: flex; align-items: center; gap: 8px; }
    .password-cell code { flex: 1; }
    .password-cell button { flex: 0 0 auto; min-width: 42px; padding: 8px 10px; }
    label { display: grid; gap: 6px; font-size: 13px; color: #cbd5e1; }
    input, textarea { width: 100%; box-sizing: border-box; background: #0b1220; color: #e5eef8; border: 1px solid #22304a; border-radius: 10px; padding: 10px 12px; }
    textarea { min-height: 96px; resize: vertical; }
    button, .btn { background: linear-gradient(180deg, #38bdf8, #0ea5e9); color: #00111d; border: 0; border-radius: 999px; padding: 10px 14px; font-weight: 700; cursor: pointer; text-decoration: none; display: inline-flex; align-items: center; gap: 6px; }
    button.secondary, .btn.secondary { background: #162033; color: #dbeafe; border: 1px solid #2a3b59; }
    button.danger, .btn.danger { background: linear-gradient(180deg, #f87171, #ef4444); color: #1c0202; }
    button.ghost, .btn.ghost { background: transparent; color: #dbeafe; border: 1px solid #2a3b59; }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; vertical-align: top; padding: 10px; border-bottom: 1px solid rgba(148,163,184,0.16); }
    th { color: #93c5fd; font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; }
    code { background: #0b1220; padding: 2px 6px; border-radius: 6px; }
    .actions { display: flex; flex-wrap: wrap; gap: 8px; }
    .small { font-size: 12px; color: #94a3b8; }
    .table-wrap { overflow: auto; }
    .flash { margin-top: 10px; padding: 10px 12px; border-radius: 10px; background: #0b1220; border: 1px solid #22304a; white-space: pre-wrap; }
    .hinbit-brand {
      position: fixed;
      top: 16px;
      left: 16px;
      z-index: 80;
      display: inline-flex;
      align-items: center;
      gap: 10px;
      padding: 10px 14px;
      border-radius: 999px;
      background: rgba(8, 15, 29, 0.82);
      border: 1px solid rgba(148,163,184,0.22);
      box-shadow: 0 12px 32px rgba(0,0,0,0.25);
      text-decoration: none;
      color: #e5eef8;
      backdrop-filter: blur(12px);
    }
    .hinbit-brand img {
      width: 22px;
      height: 22px;
      display: block;
      object-fit: contain;
    }
    .hinbit-brand span {
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.02em;
      white-space: nowrap;
    }
  </style>
</head>
<body>
  <a class="hinbit-brand" href="https://hinbit.com" target="_blank" rel="noreferrer">
    <img src="https://hinbit.com/hebrew_site/hinbit-logo-symbol.png" alt="Hinbit">
    <span>Powered by Hinbit Development</span>
  </a>
  <header>
    <div>
      <h1>DB Machines</h1>
      <div class="muted">Registry of DB machines, root credentials, and default ports.</div>
      <div class="small">${escapeHtml(String(machines.length))} machines saved</div>
    </div>
    <div class="actions">
      <a class="btn ghost" href="/manage/">Back to manage</a>
      <a class="btn ghost" href="/phpmyadmin/">phpMyAdmin</a>
      <button class="secondary" id="refreshBtn" type="button">Refresh</button>
    </div>
  </header>
  <main class="grid" style="gap:20px">
    <section class="panel">
      <h2 id="formTitle">Add DB machine</h2>
      <div class="grid two">
        <label>Machine name
          <input id="machineName" placeholder="Primary DB">
        </label>
        <label>DB host
          <input id="machineHost" placeholder="localhost, 10.0.0.5, db.example.com">
        </label>
        <label>DB root user
          <input id="machineRootUser" placeholder="root">
        </label>
        <div class="password-field">
          <label for="machineRootPassword">DB root password</label>
          <div class="password-wrap">
            <input id="machineRootPassword" type="password" placeholder="password">
            <button id="toggleRootPasswordBtn" class="ghost" type="button" aria-label="Show password">👁</button>
          </div>
        </div>
        <label>DB port
          <input id="machinePort" value="3306" placeholder="3306">
        </label>
        <label>Notes
          <textarea id="machineNotes" placeholder="Optional notes"></textarea>
        </label>
      </div>
      <div class="actions">
        <button id="saveBtn" type="button">Save machine</button>
        <button id="clearBtn" class="ghost" type="button">Clear form</button>
      </div>
      <input id="machineId" type="hidden">
      <div id="formResult" class="flash" hidden></div>
    </section>
    <section class="panel">
      <h2>Saved Machines</h2>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Host</th>
              <th>Root user</th>
              <th>Root password</th>
              <th>Port</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody id="machinesBody">${renderDbMachineRows(machines)}</tbody>
        </table>
      </div>
      <div id="listResult" class="flash" hidden></div>
    </section>
  </main>
  <script>
    const API = '/manage/api';
    const machinesBody = document.getElementById('machinesBody');
    const listResult = document.getElementById('listResult');
    const formResult = document.getElementById('formResult');
    const formTitle = document.getElementById('formTitle');
    const machineId = document.getElementById('machineId');
    const machineName = document.getElementById('machineName');
    const machineHost = document.getElementById('machineHost');
    const machineRootUser = document.getElementById('machineRootUser');
    const machineRootPassword = document.getElementById('machineRootPassword');
    const toggleRootPasswordBtn = document.getElementById('toggleRootPasswordBtn');
    const machinePort = document.getElementById('machinePort');
    const machineNotes = document.getElementById('machineNotes');
    const saveBtn = document.getElementById('saveBtn');
    const clearBtn = document.getElementById('clearBtn');
    const refreshBtn = document.getElementById('refreshBtn');
    let currentMachines = ${initialMachines};

    function escapeHtml(value) {
      return String(value ?? '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
    }

    function showMessage(el, value, ok = true) {
      el.hidden = false;
      el.style.borderColor = ok ? '#1d4ed8' : '#7f1d1d';
      el.textContent = value;
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

    function renderRows(machines) {
      machinesBody.innerHTML = machines.length
        ? machines.map((machine) => \`
          <tr>
            <td>
              <div><strong>\${escapeHtml(machine.name || '')}</strong></div>
              <div class="small">\${machine.id === '${LOCAL_DB_MACHINE_ID}' ? 'Built-in current VPS DB' : escapeHtml(machine.notes || '')}</div>
            </td>
            <td><code>\${escapeHtml(machine.host || '')}</code></td>
            <td><code>\${escapeHtml(machine.rootUser || '')}</code></td>
            <td>
              <div class="password-cell">
                <code data-machine-password="\${escapeHtml(machine.id || '')}">\${machine.rootPassword ? '••••••••' : 'n/a'}</code>
                <button class="ghost" data-machine-password-toggle="\${escapeHtml(machine.id || '')}" data-secret="\${escapeHtml(machine.rootPassword || '')}" type="button" aria-label="Show password">👁</button>
              </div>
            </td>
            <td><code>\${escapeHtml(machine.port || '3306')}</code></td>
            <td>
              <div class="actions">
                <button class="secondary" data-machine-edit="\${escapeHtml(machine.id || '')}" type="button">Edit</button>
                \${machine.id === '${LOCAL_DB_MACHINE_ID}' ? '<span class="pill">reserved</span>' : '<button class="danger" data-machine-delete="' + escapeHtml(machine.id || '') + '" type="button">Delete</button>'}
              </div>
            </td>
          </tr>
        \`).join('')
        : '<tr><td colspan="6" class="muted">No DB machines saved yet.</td></tr>';
    }

    function clearForm() {
      machineId.value = '';
      machineName.value = '';
      machineHost.value = '';
      machineRootUser.value = '';
      machineRootPassword.value = '';
      machinePort.value = '3306';
      machineNotes.value = '';
      formTitle.textContent = 'Add DB machine';
    }

    function fillForm(machine) {
      machineId.value = machine.id || '';
      machineName.value = machine.name || '';
      machineHost.value = machine.host || '';
      machineRootUser.value = machine.rootUser || '';
      machineRootPassword.value = machine.rootPassword || '';
      machinePort.value = machine.port || '3306';
      machineNotes.value = machine.notes || '';
      formTitle.textContent = 'Edit DB machine';
      machineName.focus();
    }

    async function refresh() {
      const data = await api('/db-machines');
      currentMachines = data.machines || [];
      renderRows(currentMachines);
    }

    async function saveMachine() {
      const payload = {
        id: machineId.value.trim(),
        name: machineName.value.trim(),
        host: machineHost.value.trim(),
        rootUser: machineRootUser.value.trim(),
        rootPassword: machineRootPassword.value.trim(),
        port: machinePort.value.trim(),
        notes: machineNotes.value.trim(),
      };
      const res = await api('/db-machines', {
        method: 'POST',
        body: JSON.stringify(payload),
      });
      showMessage(formResult, res.message || 'Saved DB machine');
      await refresh();
      clearForm();
    }

    document.addEventListener('click', async (event) => {
      const editBtn = event.target.closest('button[data-machine-edit]');
      if (editBtn) {
        const machine = currentMachines.find((item) => String(item.id) === String(editBtn.dataset.machineEdit));
        if (machine) fillForm(machine);
        return;
      }
      const revealBtn = event.target.closest('button[data-machine-password-toggle]');
      if (revealBtn) {
        const code = Array.from(machinesBody.querySelectorAll('code[data-machine-password]'))
          .find((el) => String(el.dataset.machinePassword || '') === String(revealBtn.dataset.machinePassword || ''));
        if (!code) return;
        const hidden = code.dataset.revealed !== 'yes';
        code.textContent = hidden ? (revealBtn.dataset.secret || '') : '••••••••';
        code.dataset.revealed = hidden ? 'yes' : 'no';
        revealBtn.textContent = hidden ? '🙈' : '👁';
        revealBtn.setAttribute('aria-label', hidden ? 'Hide password' : 'Show password');
        return;
      }
      const deleteBtn = event.target.closest('button[data-machine-delete]');
      if (deleteBtn) {
        const id = deleteBtn.dataset.machineDelete;
        if (!id) return;
        if (!confirm('Delete this DB machine?')) return;
        await api(\`/db-machines/\${encodeURIComponent(id)}\`, { method: 'DELETE' });
        showMessage(listResult, 'DB machine deleted');
        await refresh();
      }
    });

    saveBtn.addEventListener('click', async () => {
      saveBtn.disabled = true;
      try {
        await saveMachine();
      } catch (error) {
        showMessage(formResult, error.message, false);
      } finally {
        saveBtn.disabled = false;
      }
    });

    clearBtn.addEventListener('click', clearForm);
    toggleRootPasswordBtn.addEventListener('click', () => {
      const showing = machineRootPassword.type === 'text';
      machineRootPassword.type = showing ? 'password' : 'text';
      toggleRootPasswordBtn.textContent = showing ? '👁' : '🙈';
      toggleRootPasswordBtn.setAttribute('aria-label', showing ? 'Show password' : 'Hide password');
    });
    refreshBtn.addEventListener('click', async () => {
      try {
        await refresh();
      } catch (error) {
        showMessage(listResult, error.message, false);
      }
    });

    renderRows(currentMachines);
  </script>
</body>
</html>`;
}

function renderSshKeyRows(keys) {
  if (!keys.length) {
    return '<tr><td colspan="6" class="muted">No SSH keys found on this machine.</td></tr>';
  }
  return keys.map((key) => {
    const ref = escapeHtml(key.id || '');
    return `
      <tr>
        <td><strong>${escapeHtml(key.name || path.basename(key.path || ''))}</strong></td>
        <td>
          <textarea data-key-memo="${ref}" rows="3" placeholder="Memo for this key">${escapeHtml(key.memo || '')}</textarea>
        </td>
        <td><code>${escapeHtml(key.path || '')}</code></td>
        <td><code>${escapeHtml(key.fingerprint || 'n/a')}</code></td>
        <td><code class="public-key">${escapeHtml(key.publicKey || '')}</code></td>
        <td>
          <div class="actions">
            <button class="secondary" type="button" data-key-copy="${ref}">Copy public</button>
            <button class="secondary" type="button" data-key-save="${ref}">Save memo</button>
          </div>
        </td>
      </tr>
    `;
  }).join('');
}

function renderSshKeysPage() {
  const keys = readSshKeys();
  const initialKeys = JSON.stringify(keys).replace(/</g, '\\u003c');
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SSH Keys</title>
  <style>
    :root { color-scheme: dark; }
    body { margin: 0; font-family: Inter, system-ui, sans-serif; background: radial-gradient(circle at top, #11213d 0, #08111f 50%, #05070c 100%); color: #e5eef8; padding-top: 84px; }
    header, main { max-width: 1600px; margin: 0 auto; padding: 24px; }
    header { display: flex; justify-content: space-between; align-items: end; gap: 16px; }
    h1, h2 { margin: 0 0 12px; }
    .muted { color: #94a3b8; }
    .panel { background: rgba(8, 15, 29, 0.88); border: 1px solid rgba(148,163,184,0.2); border-radius: 18px; padding: 20px; box-shadow: 0 12px 40px rgba(0,0,0,0.35); }
    .grid { display: grid; gap: 16px; }
    .two { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    label { display: grid; gap: 6px; font-size: 13px; color: #cbd5e1; }
    input, textarea { width: 100%; box-sizing: border-box; background: #0b1220; color: #e5eef8; border: 1px solid #22304a; border-radius: 10px; padding: 10px 12px; }
    textarea { resize: vertical; }
    button, .btn { background: linear-gradient(180deg, #38bdf8, #0ea5e9); color: #00111d; border: 0; border-radius: 999px; padding: 10px 14px; font-weight: 700; cursor: pointer; text-decoration: none; display: inline-flex; align-items: center; gap: 6px; }
    button.secondary, .btn.secondary { background: #162033; color: #dbeafe; border: 1px solid #2a3b59; }
    button.danger, .btn.danger { background: linear-gradient(180deg, #f87171, #ef4444); color: #1c0202; }
    button.ghost, .btn.ghost { background: transparent; color: #dbeafe; border: 1px solid #2a3b59; }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; vertical-align: top; padding: 10px; border-bottom: 1px solid rgba(148,163,184,0.16); }
    th { color: #93c5fd; font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; }
    code { background: #0b1220; padding: 2px 6px; border-radius: 6px; word-break: break-all; white-space: pre-wrap; }
    .actions { display: flex; flex-wrap: wrap; gap: 8px; }
    .table-wrap { overflow: auto; }
    .flash { margin-top: 10px; padding: 10px 12px; border-radius: 10px; background: #0b1220; border: 1px solid #22304a; white-space: pre-wrap; }
    .hinbit-brand {
      position: fixed;
      top: 16px;
      left: 16px;
      z-index: 80;
      display: inline-flex;
      align-items: center;
      gap: 10px;
      padding: 10px 14px;
      border-radius: 999px;
      background: rgba(8, 15, 29, 0.82);
      border: 1px solid rgba(148,163,184,0.22);
      box-shadow: 0 12px 32px rgba(0,0,0,0.25);
      text-decoration: none;
      color: #e5eef8;
      backdrop-filter: blur(12px);
    }
    .hinbit-brand img {
      width: 22px;
      height: 22px;
      display: block;
      object-fit: contain;
    }
    .hinbit-brand span {
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.02em;
      white-space: nowrap;
    }
    .public-key { display: block; max-width: 520px; }
  </style>
</head>
<body>
  <a class="hinbit-brand" href="https://hinbit.com" target="_blank" rel="noreferrer">
    <img src="https://hinbit.com/hebrew_site/hinbit-logo-symbol.png" alt="Hinbit">
    <span>Powered by Hinbit Development</span>
  </a>
  <header>
    <div>
      <h1>SSH Keys</h1>
      <div class="muted">Existing keys on the machine with memos and new GitHub-ready key generation.</div>
      <div class="small">${escapeHtml(String(keys.length))} keys found</div>
    </div>
    <div class="actions">
      <a class="btn ghost" href="/manage/">Back to manage</a>
      <a class="btn ghost" href="/phpmyadmin/">phpMyAdmin</a>
      <button class="secondary" id="refreshBtn" type="button">Refresh</button>
    </div>
  </header>
  <main class="grid" style="gap:20px">
    <section class="panel">
      <h2>Create SSH Key</h2>
      <div class="grid two">
        <label>Key name
          <input id="keyName" placeholder="github-shaykid">
        </label>
        <label>Memo
          <input id="keyMemo" placeholder="GitHub account or project note">
        </label>
      </div>
      <div class="actions">
        <button id="createBtn" type="button">Create key</button>
      </div>
      <div class="small">The public key can be copied from the table below and added to GitHub.</div>
      <div id="createResult" class="flash" hidden></div>
    </section>
    <section class="panel">
      <h2>Saved Keys</h2>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Memo</th>
              <th>Path</th>
              <th>Fingerprint</th>
              <th>Public key</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody id="keysBody">${renderSshKeyRows(keys)}</tbody>
        </table>
      </div>
      <div id="listResult" class="flash" hidden></div>
    </section>
  </main>
  <script>
    const API = '/manage/api';
    const keysBody = document.getElementById('keysBody');
    const listResult = document.getElementById('listResult');
    const createResult = document.getElementById('createResult');
    const keyName = document.getElementById('keyName');
    const keyMemo = document.getElementById('keyMemo');
    const createBtn = document.getElementById('createBtn');
    const refreshBtn = document.getElementById('refreshBtn');
    let currentKeys = ${initialKeys};

    function escapeHtml(value) {
      return String(value ?? '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
    }

    function showMessage(el, value, ok = true) {
      el.hidden = false;
      el.style.borderColor = ok ? '#1d4ed8' : '#7f1d1d';
      el.textContent = value;
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

    function renderRows(keys) {
      keysBody.innerHTML = keys.length
        ? keys.map((key) => \`
          <tr>
            <td><strong>\${escapeHtml(key.name || '')}</strong></td>
            <td>
              <textarea data-key-memo="\${escapeHtml(key.id || '')}" rows="3">\${escapeHtml(key.memo || '')}</textarea>
            </td>
            <td><code>\${escapeHtml(key.path || '')}</code></td>
            <td><code>\${escapeHtml(key.fingerprint || 'n/a')}</code></td>
            <td><code class="public-key">\${escapeHtml(key.publicKey || '')}</code></td>
            <td>
              <div class="actions">
                <button class="secondary" data-key-copy="\${escapeHtml(key.id || '')}" type="button">Copy public</button>
                <button class="secondary" data-key-save="\${escapeHtml(key.id || '')}" type="button">Save memo</button>
              </div>
            </td>
          </tr>
        \`).join('')
        : '<tr><td colspan="6" class="muted">No SSH keys found on this machine.</td></tr>';
    }

    async function refresh() {
      const data = await api('/ssh-keys');
      currentKeys = data.keys || [];
      renderRows(currentKeys);
    }

    async function createKey() {
      const payload = {
        name: keyName.value.trim(),
        memo: keyMemo.value.trim(),
      };
      const res = await api('/ssh-keys', {
        method: 'POST',
        body: JSON.stringify(payload),
      });
      showMessage(createResult, res.message || 'SSH key created');
      await refresh();
      keyName.value = '';
      keyMemo.value = '';
    }

    document.addEventListener('click', async (event) => {
      const copyBtn = event.target.closest('button[data-key-copy]');
      if (copyBtn) {
        const key = currentKeys.find((item) => String(item.id) === String(copyBtn.dataset.keyCopy || ''));
        if (!key || !key.publicKey) return;
        await navigator.clipboard.writeText(key.publicKey);
        showMessage(listResult, 'Public key copied');
        return;
      }
      const saveBtn = event.target.closest('button[data-key-save]');
      if (saveBtn) {
        const key = currentKeys.find((item) => String(item.id) === String(saveBtn.dataset.keySave || ''));
        if (!key) return;
        const memoField = keysBody.querySelector(\`[data-key-memo="\${CSS.escape(String(key.id || ''))}"]\`);
        const memo = memoField ? memoField.value : '';
        const res = await api(\`/ssh-keys/\${encodeURIComponent(key.id)}\`, {
          method: 'POST',
          body: JSON.stringify({ memo }),
        });
        showMessage(listResult, res.message || 'Memo saved');
        await refresh();
      }
    });

    createBtn.addEventListener('click', async () => {
      createBtn.disabled = true;
      try {
        await createKey();
      } catch (error) {
        showMessage(createResult, error.message, false);
      } finally {
        createBtn.disabled = false;
      }
    });

    refreshBtn.addEventListener('click', async () => {
      try {
        await refresh();
      } catch (error) {
        showMessage(listResult, error.message, false);
      }
    });

    renderRows(currentKeys);
  </script>
</body>
</html>`;
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

function streamProjectCtl(res, args) {
  const child = spawn(PROJECTCTL, args, {
    cwd: '/',
    env: process.env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  res.writeHead(200, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Accel-Buffering': 'no',
  });

  const writeChunk = (chunk) => {
    if (!res.writableEnded) {
      res.write(chunk);
    }
  };

  child.stdout.on('data', (chunk) => writeChunk(chunk));
  child.stderr.on('data', (chunk) => writeChunk(chunk));

  child.on('close', (code) => {
    if (!res.writableEnded) {
      if (code === 0) {
        res.end('\n[done]\n');
      } else {
        res.end(`\n[error] projectctl exited with code ${code}\n`);
      }
    }
  });

  child.on('error', (error) => {
    if (!res.writableEnded) {
      res.statusCode = 500;
      res.end(`[error] ${error.message || String(error)}\n`);
    }
  });
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
  const dbMachines = readDbMachines();
  const dbMachineOptions = renderDbMachineOptions(dbMachines, LOCAL_DB_MACHINE_ID);
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>MultiDev Manage</title>
  <style>
    :root { color-scheme: dark; }
    body { margin: 0; font-family: Inter, system-ui, sans-serif; background: radial-gradient(circle at top, #11213d 0, #08111f 50%, #05070c 100%); color: #e5eef8; }
    body { padding-top: 84px; }
    header, main { max-width: 1400px; margin: 0 auto; padding: 24px; }
    header { display: flex; justify-content: space-between; align-items: end; gap: 16px; }
    h1, h2 { margin: 0 0 12px; }
    .muted { color: #94a3b8; }
    .panel { background: rgba(8, 15, 29, 0.88); border: 1px solid rgba(148,163,184,0.2); border-radius: 18px; padding: 20px; box-shadow: 0 12px 40px rgba(0,0,0,0.35); }
    .grid { display: grid; gap: 16px; }
    .two { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .three { grid-template-columns: repeat(3, minmax(0, 1fr)); }
    .password-field { display: grid; gap: 6px; }
    .password-wrap { display: flex; align-items: stretch; gap: 8px; }
    .password-wrap input { flex: 1; }
    .password-wrap button { flex: 0 0 auto; min-width: 48px; padding: 10px 12px; }
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
    .password-field { display: grid; gap: 6px; }
    .password-wrap { display: flex; align-items: stretch; gap: 8px; }
    .password-wrap input { flex: 1; }
    .password-wrap button { flex: 0 0 auto; min-width: 48px; padding: 10px 12px; }
    .password-cell { display: flex; align-items: center; gap: 8px; }
    .password-cell code { flex: 1; }
    .password-cell button { flex: 0 0 auto; min-width: 42px; padding: 8px 10px; }
    .sticky { position: sticky; top: 0; z-index: 5; backdrop-filter: blur(12px); }
    .space { height: 12px; }
    .pill { display: inline-flex; padding: 3px 8px; border-radius: 999px; background: #102338; border: 1px solid #23405f; font-size: 12px; }
    .pill.good { background: #0f3a24; border-color: #14532d; color: #86efac; }
    .pill.warn { background: #3f2d0c; border-color: #7c2d12; color: #fde68a; }
    .pill.neutral { background: #1f2937; border-color: #334155; color: #cbd5e1; }
    .table-wrap { overflow: auto; }
    .flash { margin-top: 10px; padding: 10px 12px; border-radius: 10px; background: #0b1220; border: 1px solid #22304a; white-space: pre-wrap; }
    .scripts-panel { background: #08111f; border: 1px solid #22304a; border-radius: 18px; box-shadow: 0 30px 80px rgba(0,0,0,0.35); margin: 0 24px 24px; }
    .modal-panel {
      position: fixed;
      inset: 0;
      z-index: 60;
      margin: 0;
      padding: 24px;
      background: rgba(2, 6, 23, 0.76);
      backdrop-filter: blur(12px);
      border: 0;
      border-radius: 0;
      box-shadow: none;
      overflow: auto;
      display: grid;
      gap: 16px;
      align-content: start;
      justify-items: center;
    }
    .modal-panel > header,
    .modal-panel > .body {
      width: min(1100px, calc(100vw - 48px));
      box-sizing: border-box;
    }
    .modal-panel[hidden] {
      display: none !important;
    }
    .modal-panel > header {
      padding: 18px 20px 0;
    }
    .modal-panel > .body {
      padding: 18px 20px 20px;
    }
    .scripts-panel header { padding: 18px 20px 0; display: flex; justify-content: space-between; align-items: center; gap: 16px; }
    .scripts-panel .body { padding: 18px 20px 20px; }
    .script-list { display: grid; gap: 10px; }
    .script-row { display: grid; grid-template-columns: 1fr auto; gap: 12px; align-items: start; padding: 12px; border: 1px solid #22304a; border-radius: 12px; background: #0b1220; }
    .script-row code { white-space: pre-wrap; }
    .kv-list { display: grid; gap: 10px; }
    .kv-item { display: grid; gap: 4px; padding: 12px; border: 1px solid #22304a; border-radius: 12px; background: #0b1220; }
    .kv-item code { white-space: pre-wrap; word-break: break-word; }
    .copy-actions { display: flex; flex-wrap: wrap; gap: 6px; }
    .copy-actions .btn, .copy-actions button { padding: 8px 10px; font-size: 12px; }
    .hinbit-brand {
      position: fixed;
      top: 16px;
      left: 16px;
      z-index: 80;
      display: inline-flex;
      align-items: center;
      gap: 10px;
      padding: 10px 14px;
      border-radius: 999px;
      background: rgba(8, 15, 29, 0.82);
      border: 1px solid rgba(148,163,184,0.22);
      box-shadow: 0 12px 32px rgba(0,0,0,0.25);
      text-decoration: none;
      color: #e5eef8;
      backdrop-filter: blur(12px);
    }
    .hinbit-brand img {
      width: 22px;
      height: 22px;
      display: block;
      object-fit: contain;
    }
    .hinbit-brand span {
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.02em;
      white-space: nowrap;
    }
  </style>
</head>
<body>
  <a class="hinbit-brand" href="https://hinbit.com" target="_blank" rel="noreferrer">
    <img src="https://hinbit.com/hebrew_site/hinbit-logo-symbol.png" alt="Hinbit">
    <span>Powered by Hinbit Development</span>
  </a>
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
        <label>DB machine
          <select id="dbMachineId">${dbMachineOptions}</select>
        </label>
      </div>
      <div class="space"></div>
      <div class="grid two">
        <label>Env file contents
          <textarea id="envText" placeholder="Paste .env contents here if needed"></textarea>
        </label>
        <div class="password-field">
          <label for="accessPassword">Project access password</label>
          <div class="password-wrap">
            <input id="accessPassword" type="password" placeholder="Optional: set a password for the project domain after install">
            <button id="toggleAccessPasswordBtn" class="ghost" type="button" aria-label="Show password">👁</button>
          </div>
        </div>
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
              <th>RAM</th>
              <th>Disk</th>
              <th>Status</th>
              <th>Protected</th>
              <th>SSL</th>
              <th>Branch</th>
              <th>Details</th>
            </tr>
          </thead>
          <tbody id="projectsBody"></tbody>
        </table>
      </div>
      <div id="listResult" class="flash" hidden></div>
    </section>
  </main>
  <div id="scriptsPanel" class="scripts-panel modal-panel" hidden>
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
  <div id="dbPanel" class="scripts-panel modal-panel" hidden>
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
  <div id="mysqlPanel" class="scripts-panel modal-panel" hidden>
    <header>
      <div>
        <h2 id="mysqlTitle">MySQL Access</h2>
        <div id="mysqlSubtitle" class="muted"></div>
      </div>
      <button id="closeMysqlBtn" class="ghost" type="button">Close</button>
    </header>
    <div class="body">
      <div id="mysqlFlash" class="flash" hidden></div>
      <div class="grid two">
        <div class="kv-list" id="mysqlDetails"></div>
        <div class="stack">
          <label>DB machine
            <select id="mysqlMachineSelect"></select>
          </label>
          <label>Allowed IPs / CIDRs
            <textarea id="mysqlIpsInput" placeholder="198.51.100.10,203.0.113.0/24"></textarea>
          </label>
          <div class="actions">
            <a id="mysqlPhpMyAdminBtn" class="btn ghost" href="/phpmyadmin/" target="_blank" rel="noreferrer">phpMyAdmin</a>
            <button id="mysqlSaveBtn" class="secondary" type="button">Save & move</button>
          </div>
          <div id="mysqlAccounts" class="kv-list"></div>
        </div>
      </div>
    </div>
  </div>
  <div id="sshPanel" class="scripts-panel modal-panel" hidden>
    <header>
      <div>
        <h2 id="sshTitle">SSH Upload Access</h2>
        <div id="sshSubtitle" class="muted"></div>
      </div>
      <button id="closeSshBtn" class="ghost" type="button">Close</button>
    </header>
    <div class="body">
      <div id="sshFlash" class="flash" hidden></div>
      <div class="grid two">
        <div class="kv-list" id="sshDetails"></div>
        <div class="stack">
          <div class="kv-item">
            <div class="small">How to connect</div>
            <div class="small">Use SFTP over port 22 with the upload user and password below.</div>
          </div>
          <div class="kv-item">
            <div class="small">Copy</div>
            <div class="copy-actions">
              <button id="sshCopyUserBtn" class="secondary" type="button">Copy user</button>
              <button id="sshCopyPassBtn" class="secondary" type="button">Copy pass</button>
              <button id="sshCopyAllBtn" class="ghost" type="button">Copy all</button>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
  <div id="envPanel" class="scripts-panel modal-panel" hidden>
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
  <div id="progressPanel" class="scripts-panel modal-panel" hidden>
    <header>
      <div>
        <h2 id="progressTitle">Pull Progress</h2>
        <div id="progressSubtitle" class="muted"></div>
      </div>
      <button id="closeProgressBtn" class="ghost" type="button">Close</button>
    </header>
    <div class="body">
      <div id="progressFlash" class="flash" hidden></div>
      <pre id="progressBody" class="kv-item" style="margin:0; max-height: 60vh; overflow:auto; white-space: pre-wrap;"></pre>
    </div>
  </div>
  <div id="logPanel" class="scripts-panel modal-panel" hidden>
    <header>
      <div>
        <h2 id="logTitle">Live Log</h2>
        <div id="logSubtitle" class="muted"></div>
      </div>
      <div class="actions">
        <button id="logOutBtn" class="secondary" type="button">Out</button>
        <button id="logErrBtn" class="secondary" type="button">Err</button>
        <button id="logClearOutBtn" class="danger" type="button">Clear out</button>
        <button id="logClearErrBtn" class="danger" type="button">Clear err</button>
        <button id="logRefreshBtn" class="secondary" type="button">Refresh</button>
        <button id="closeLogBtn" class="ghost" type="button">Close</button>
      </div>
    </header>
    <div class="body">
      <div id="logFlash" class="flash" hidden></div>
      <pre id="logBody" class="kv-item" style="margin:0; max-height: 60vh; overflow:auto; white-space: pre-wrap;"></pre>
    </div>
  </div>
  <script>
    const API = '/manage/api';
    const projectsBody = document.getElementById('projectsBody');
    const listResult = document.getElementById('listResult');
    const installResult = document.getElementById('installResult');
    const systemStats = document.getElementById('systemStats');
    const dbMachineSelect = document.getElementById('dbMachineId');
    const toggleAccessPasswordBtn = document.getElementById('toggleAccessPasswordBtn');
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
    const mysqlPanel = document.getElementById('mysqlPanel');
    const mysqlTitle = document.getElementById('mysqlTitle');
    const mysqlSubtitle = document.getElementById('mysqlSubtitle');
    const mysqlDetails = document.getElementById('mysqlDetails');
    const mysqlFlash = document.getElementById('mysqlFlash');
    const mysqlMachineSelect = document.getElementById('mysqlMachineSelect');
    const mysqlIpsInput = document.getElementById('mysqlIpsInput');
    const mysqlAccounts = document.getElementById('mysqlAccounts');
    const mysqlPhpMyAdminBtn = document.getElementById('mysqlPhpMyAdminBtn');
    const mysqlSaveBtn = document.getElementById('mysqlSaveBtn');
    const closeMysqlBtn = document.getElementById('closeMysqlBtn');
    const sshPanel = document.getElementById('sshPanel');
    const sshTitle = document.getElementById('sshTitle');
    const sshSubtitle = document.getElementById('sshSubtitle');
    const sshDetails = document.getElementById('sshDetails');
    const sshFlash = document.getElementById('sshFlash');
    const closeSshBtn = document.getElementById('closeSshBtn');
    const sshCopyUserBtn = document.getElementById('sshCopyUserBtn');
    const sshCopyPassBtn = document.getElementById('sshCopyPassBtn');
    const sshCopyAllBtn = document.getElementById('sshCopyAllBtn');
    const envPanel = document.getElementById('envPanel');
    const envTitle = document.getElementById('envTitle');
    const envSubtitle = document.getElementById('envSubtitle');
    const envList = document.getElementById('envList');
    const envFlash = document.getElementById('envFlash');
    const envDownloadBtn = document.getElementById('envDownloadBtn');
    const envUploadInput = document.getElementById('envUploadInput');
    const envUploadBtn = document.getElementById('envUploadBtn');
    const closeEnvBtn = document.getElementById('closeEnvBtn');
    const progressPanel = document.getElementById('progressPanel');
    const progressTitle = document.getElementById('progressTitle');
    const progressSubtitle = document.getElementById('progressSubtitle');
    const progressBody = document.getElementById('progressBody');
    const progressFlash = document.getElementById('progressFlash');
    const closeProgressBtn = document.getElementById('closeProgressBtn');
    const logPanel = document.getElementById('logPanel');
    const logTitle = document.getElementById('logTitle');
    const logSubtitle = document.getElementById('logSubtitle');
    const logBody = document.getElementById('logBody');
    const logFlash = document.getElementById('logFlash');
    const logOutBtn = document.getElementById('logOutBtn');
    const logErrBtn = document.getElementById('logErrBtn');
    const logClearOutBtn = document.getElementById('logClearOutBtn');
    const logClearErrBtn = document.getElementById('logClearErrBtn');
    const logRefreshBtn = document.getElementById('logRefreshBtn');
    const closeLogBtn = document.getElementById('closeLogBtn');
    let currentScriptsRef = '';
    let currentDbRef = '';
    let currentMysqlRef = '';
    let currentSshRef = '';
    let currentEnvRef = '';
    let currentLogRef = '';
    let currentLogType = 'out';
    let currentProjects = [];
    let currentDbMachines = [];
    let progressAbort = null;
    let logTimer = null;
    let modalLockCount = 0;

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
      return (size >= 10 || unit === 0 ? size.toFixed(0) : size.toFixed(1)) + ' ' + units[unit];
    }

    function renderDbMachineSelectOptions(machines, selectedId) {
      const list = Array.isArray(machines) && machines.length ? machines : [{ id: '${LOCAL_DB_MACHINE_ID}', name: 'localhost (current)', host: '127.0.0.1' }];
      return list.map((machine) => {
        const id = String(machine.id || '');
        const label = (machine.name || id) + (machine.host ? ' · ' + machine.host : '');
        return '<option value="' + escapeHtml(id) + '"' + (id === String(selectedId || '') ? ' selected' : '') + '>' + escapeHtml(label) + '</option>';
      }).join('');
    }

    function syncDbMachineSelects(selectedId) {
      if (dbMachineSelect) {
        dbMachineSelect.innerHTML = renderDbMachineSelectOptions(currentDbMachines, selectedId || dbMachineSelect.value || '${LOCAL_DB_MACHINE_ID}');
      }
      if (mysqlMachineSelect) {
        mysqlMachineSelect.innerHTML = renderDbMachineSelectOptions(currentDbMachines, selectedId || mysqlMachineSelect.value || '${LOCAL_DB_MACHINE_ID}');
      }
    }

    function setModalLocked(locked) {
      if (locked) {
        modalLockCount += 1;
        if (modalLockCount === 1) {
          document.body.style.overflow = 'hidden';
        }
        return;
      }
      modalLockCount = Math.max(0, modalLockCount - 1);
      if (!modalLockCount) {
        document.body.style.overflow = '';
      }
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

    async function fetchText(path, options = {}) {
      const res = await fetch(\`\${API}\${path}\`, {
        credentials: 'same-origin',
        ...options,
      });
      const text = await res.text();
      if (!res.ok) {
        throw new Error(text || \`Request failed: \${res.status}\`);
      }
      return text;
    }

    async function refresh() {
      const [dataResult, statsResult, machinesResult] = await Promise.allSettled([
        api('/projects'),
        api('/system'),
        api('/db-machines'),
      ]);
      if (dataResult.status !== 'fulfilled') throw dataResult.reason;
      const data = dataResult.value;
      currentProjects = data.projects || [];
      renderProjects(currentProjects);
      currentDbMachines = machinesResult.status === 'fulfilled' ? (machinesResult.value.machines || []) : [];
      syncDbMachineSelects(dbMachineSelect ? dbMachineSelect.value : '${LOCAL_DB_MACHINE_ID}');
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
      return \`
        <div class="actions">
          \${project.domain ? '<a class="btn ghost" href="https://' + escapeHtml(project.domain) + '/" target="_blank" rel="noreferrer">Open</a>' : ''}
          <button class="secondary" data-action="update" data-ref="\${ref}">Pull</button>
          <button class="secondary" data-action="restart" data-ref="\${ref}">Restart</button>
          <button class="secondary" data-action="stop" data-ref="\${ref}">Stop</button>
          <button class="danger" data-action="uninstall" data-ref="\${ref}">Kill</button>
          <button class="secondary" data-action="db" data-ref="\${ref}">DB</button>
          <button class="secondary" data-action="mysql" data-ref="\${ref}">MySQL</button>
          <button class="secondary" data-action="ssh" data-ref="\${ref}">SSH</button>
          <button class="secondary" data-action="env" data-ref="\${ref}">Env</button>
          <button class="secondary" data-action="scripts" data-ref="\${ref}">Scripts</button>
          <button class="secondary" data-action="log" data-ref="\${ref}">Log</button>
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
        projectsBody.innerHTML = '<tr><td colspan="11" class="muted">No projects found.</td></tr>';
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
            <div class="small">\${project.https === 'yes' ? 'HTTPS' : 'HTTP only'} · <span class="pill \${escapeHtml(project.sslStatusClass || 'neutral')}">\${escapeHtml(project.sslStatus || 'n/a')}</span></div>
          </td>
          <td>
            <div><code>\${escapeHtml(project.pm2 || '')}</code></div>
            <div class="small">\${escapeHtml(project.scriptPath || '')}</div>
          </td>
          <td>\${escapeHtml(project.port || '')}</td>
          <td>\${escapeHtml(formatBytes(project.memory || 0))}</td>
          <td>\${escapeHtml(project.diskHuman || formatBytes(project.disk || 0))}</td>
          <td><span class="\${statusClass(project.status)}">\${escapeHtml(project.status || '')}</span></td>
          <td>\${project.protected ? 'yes' : 'no'}</td>
          <td><span class="pill \${escapeHtml(project.sslStatusClass || 'neutral')}">\${escapeHtml(project.sslStatus || 'n/a')}</span></td>
          <td>\${escapeHtml(project.branch || '')}</td>
          <td class="small">
            kind: \${escapeHtml(project.kind || '')}<br>
            type: \${escapeHtml(project.type || '')}<br>
            pm: \${escapeHtml(project.packageManager || '')}<br>
            restarts: \${escapeHtml(String(project.restarts ?? 0))}<br>
            uptime: \${escapeHtml(fmtTime(project.uptime))}<br>
            env: \${escapeHtml(project.nodeEnv || '')}<br>
            ram: \${escapeHtml(project.memory ? formatBytes(project.memory) : '0 B')}<br>
            disk: \${escapeHtml(project.diskHuman || formatBytes(project.disk || 0))}<br>
            ssh: \${escapeHtml(project.sshUser || 'n/a')}<br>
            mysql ips: \${escapeHtml(project.mysqlAllowedIps || 'local only')}
          </td>
        </tr>
        <tr class="project-actions-row">
          <td colspan="11">\${rowActions(project)}</td>
        </tr>
      \`).join('');
    }

    function openScriptsModal(ref, scripts, subtitle) {
      closeDbPanel();
      closeMysqlPanel();
      closeEnvPanel();
      closeProgressPanel();
      closeLogPanel();
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
      setModalLocked(true);
    }

    function closeScriptsModal() {
      scriptsPanel.hidden = true;
      currentScriptsRef = '';
      scriptsList.innerHTML = '';
      scriptsFlash.hidden = true;
      setModalLocked(false);
    }

    function openDbPanel(ref, details, subtitle) {
      closeScriptsModal();
      closeMysqlPanel();
      closeEnvPanel();
      closeProgressPanel();
      closeLogPanel();
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
      setModalLocked(true);
    }

    function closeDbPanel() {
      dbPanel.hidden = true;
      currentDbRef = '';
      dbList.innerHTML = '';
      dbFlash.hidden = true;
      setModalLocked(false);
    }

    function openMysqlPanel(ref, details, subtitle) {
      closeScriptsModal();
      closeDbPanel();
      closeEnvPanel();
      closeProgressPanel();
      closeLogPanel();
      currentMysqlRef = ref;
      mysqlTitle.textContent = 'MySQL Access';
      mysqlSubtitle.textContent = subtitle || '';
      mysqlFlash.hidden = true;
      mysqlPhpMyAdminBtn.href = '/phpmyadmin/';
      mysqlIpsInput.value = details.allowedIps || '';
      currentDbMachines = Array.isArray(details.machines) && details.machines.length ? details.machines : currentDbMachines;
      if (mysqlMachineSelect) {
        mysqlMachineSelect.innerHTML = renderDbMachineSelectOptions(currentDbMachines, details.dbMachineId || '${LOCAL_DB_MACHINE_ID}');
        mysqlMachineSelect.value = details.dbMachineId || '${LOCAL_DB_MACHINE_ID}';
      }
      const rows = [
        ['DB supplier', details.db?.DB_SUPPLIER || 'n/a'],
        ['Database name', details.db?.DB_NAME || details.db?.DB_DATABASE || details.db?.MYSQL_DATABASE || details.db?.POSTGRES_DB || 'n/a'],
        ['Database user', details.db?.DB_USER || details.db?.MYSQL_USER || details.db?.POSTGRES_USER || 'n/a'],
        ['Database password', details.db?.DB_PASSWORD || details.db?.MYSQL_PASSWORD || details.db?.POSTGRES_PASSWORD || 'n/a'],
        ['DB machine', details.dbMachineId || 'local-current'],
        ['Database host', details.db?.DB_HOST || details.db?.MYSQL_HOST || details.db?.POSTGRES_HOST || 'n/a'],
        ['Database port', details.db?.DB_PORT || details.db?.MYSQL_PORT || details.db?.POSTGRES_PORT || 'n/a'],
        ['Allowed IPs', details.allowedIps || 'local only'],
      ];
      const sources = (details.files || []).map((file) => escapeHtml(file)).join('<br>');
      mysqlDetails.innerHTML = \`
        \${rows.map(([label, value]) => \`
          <div class="kv-item">
            <div class="small">\${escapeHtml(label)}</div>
            <code>\${escapeHtml(value)}</code>
          </div>
        \`).join('')}
        <div class="kv-item">
          <div class="small">Source files</div>
          <div class="small">\${sources || 'n/a'}</div>
        </div>
      \`;
      mysqlAccounts.innerHTML = details.accounts && details.accounts.length
        ? details.accounts.map((account) => \`
          <div class="kv-item">
            <div class="small">Account</div>
            <code>\${escapeHtml(account)}</code>
          </div>
        \`).join('')
        : '<div class="muted">No MySQL account rows found.</div>';
      mysqlPanel.hidden = false;
      setModalLocked(true);
    }

    function closeMysqlPanel() {
      mysqlPanel.hidden = true;
      currentMysqlRef = '';
      mysqlDetails.innerHTML = '';
      mysqlAccounts.innerHTML = '';
      mysqlIpsInput.value = '';
      mysqlFlash.hidden = true;
      setModalLocked(false);
    }

    function openSshPanel(ref, details, subtitle) {
      closeScriptsModal();
      closeDbPanel();
      closeMysqlPanel();
      closeEnvPanel();
      closeProgressPanel();
      closeLogPanel();
      currentSshRef = ref;
      sshTitle.textContent = 'SSH Upload Access';
      sshSubtitle.textContent = subtitle || '';
      sshFlash.hidden = true;
      const rows = [
        ['SSH user', details.user || 'n/a'],
        ['SSH password', details.password || 'n/a'],
        ['Home', details.home || 'n/a'],
        ['Host', details.host || window.location.hostname || 'n/a'],
        ['Port', details.port || '22'],
        ['Mode', details.mode || 'sftp-only'],
      ];
      sshDetails.innerHTML = \`
        \${rows.map(([label, value]) => \`
          <div class="kv-item">
            <div class="small">\${escapeHtml(label)}</div>
            <code>\${escapeHtml(value)}</code>
          </div>
        \`).join('')}
      \`;
      sshPanel.hidden = false;
      setModalLocked(true);
    }

    function closeSshPanel() {
      sshPanel.hidden = true;
      currentSshRef = '';
      sshDetails.innerHTML = '';
      sshFlash.hidden = true;
      setModalLocked(false);
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
      closeScriptsModal();
      closeDbPanel();
      closeMysqlPanel();
      closeProgressPanel();
      closeLogPanel();
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
      setModalLocked(true);
    }

    function closeEnvPanel() {
      envPanel.hidden = true;
      currentEnvRef = '';
      envList.innerHTML = '';
      envFlash.hidden = true;
      envUploadInput.value = '';
      setModalLocked(false);
    }

    function openProgressPanel(ref, subtitle) {
      closeScriptsModal();
      closeDbPanel();
      closeEnvPanel();
      closeMysqlPanel();
      closeLogPanel();
      progressTitle.textContent = 'Pull Progress';
      progressSubtitle.textContent = subtitle || ref || '';
      progressBody.textContent = '';
      progressFlash.hidden = true;
      progressPanel.hidden = false;
      setModalLocked(true);
    }

    function closeProgressPanel() {
      if (progressAbort) {
        progressAbort.abort();
        progressAbort = null;
      }
      progressPanel.hidden = true;
      progressBody.textContent = '';
      progressFlash.hidden = true;
      setModalLocked(false);
    }

    function openLogPanel(ref, type) {
      closeScriptsModal();
      closeDbPanel();
      closeEnvPanel();
      closeMysqlPanel();
      closeProgressPanel();
      currentLogRef = ref;
      currentLogType = type || 'out';
      logTitle.textContent = 'Live Log';
      logSubtitle.textContent = ref + ' · ' + (currentLogType === 'error' ? 'error' : 'output');
      logBody.textContent = '';
      logFlash.hidden = true;
      logPanel.hidden = false;
      setModalLocked(true);
    }

    function closeLogPanel() {
      currentLogRef = '';
      currentLogType = 'out';
      logBody.textContent = '';
      logFlash.hidden = true;
      logPanel.hidden = true;
      if (logTimer) {
        clearInterval(logTimer);
        logTimer = null;
      }
      setModalLocked(false);
    }

    async function loadLog(ref, type = 'out') {
      const text = await fetchText('/projects/' + ref + '/logs?type=' + encodeURIComponent(type) + '&lines=400');
      logBody.textContent = text || '(no log data)\\n';
      logSubtitle.textContent = decodeURIComponent(ref) + ' · ' + (type === 'error' ? 'error' : 'output') + ' · Asia/Jerusalem';
      logBody.scrollTop = logBody.scrollHeight;
    }

    async function clearLog(ref, type = 'out') {
      const label = type === 'error' ? 'error' : 'output';
      const res = await api('/projects/' + ref + '/logs/clear', {
        method: 'POST',
        body: JSON.stringify({ type }),
      });
      showMessage(logFlash, res.message || 'Cleared ' + label + ' log');
      await loadLog(ref, currentLogType);
    }

    async function runPullWithProgress(ref) {
      if (progressAbort) {
        progressAbort.abort();
      }
      progressAbort = new AbortController();
      openProgressPanel(decodeURIComponent(ref), 'Pulling ' + decodeURIComponent(ref));
      try {
        const res = await fetch(API + '/projects/' + ref + '/update-stream', {
          method: 'POST',
          credentials: 'same-origin',
          signal: progressAbort.signal,
        });
        if (!res.ok || !res.body) {
          const text = await res.text();
          throw new Error(text || 'Request failed: ' + res.status);
        }
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          progressBody.textContent = buffer;
          progressBody.scrollTop = progressBody.scrollHeight;
        }
        buffer += decoder.decode();
        if (buffer.trim()) {
          progressBody.textContent = buffer;
        }
      } catch (error) {
        showMessage(progressFlash, error.message, false);
        progressFlash.hidden = false;
      } finally {
        progressAbort = null;
      }
    }

    async function loadScripts(ref) {
      const data = await api(\`/projects/\${ref}/scripts\`);
      openScriptsModal(ref, data.scripts || [], data.project || ref);
    }

    async function loadDb(ref) {
      const data = await api(\`/projects/\${ref}/db\`);
      openDbPanel(ref, data.db || {}, data.project || ref);
    }

    async function loadMysql(ref) {
      const data = await api(\`/projects/\${ref}/mysql\`);
      openMysqlPanel(ref, data, data.project || ref);
    }

    async function loadSsh(ref) {
      const data = await api(\`/projects/\${ref}/ssh\`);
      openSshPanel(ref, data, data.project || ref);
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

    async function saveMysql(ref, ips) {
      const machineId = mysqlMachineSelect ? mysqlMachineSelect.value : '';
      const res = await api(\`/projects/\${ref}/mysql\`, {
        method: 'POST',
        body: JSON.stringify({ ips, machineId }),
      });
      await loadMysql(ref);
      showMessage(mysqlFlash, res.message || 'MySQL permissions updated');
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
      if (action === 'db' || action === 'env' || action === 'mysql') {
        return;
      }
      if (action === 'ssh') {
        btn.disabled = true;
        try {
          await loadSsh(ref);
        } catch (error) {
          showMessage(sshFlash, error.message, false);
          sshPanel.hidden = false;
        } finally {
          btn.disabled = false;
        }
        return;
      }
      if (action === 'log') {
        btn.disabled = true;
        try {
          openLogPanel(ref, currentLogType);
          await loadLog(ref, currentLogType);
          if (logTimer) clearInterval(logTimer);
          logTimer = setInterval(() => {
            if (currentLogRef) {
              loadLog(currentLogRef, currentLogType).catch((error) => {
                showMessage(logFlash, error.message, false);
              });
            }
          }, 3000);
        } catch (error) {
          showMessage(logFlash, error.message, false);
          logPanel.hidden = false;
        } finally {
          btn.disabled = false;
        }
        return;
      }
      if (action === 'update') {
        btn.disabled = true;
        try {
          await runPullWithProgress(ref);
        } catch (error) {
          showMessage(progressFlash, error.message, false);
          progressPanel.hidden = false;
        } finally {
          btn.disabled = false;
        }
        return;
      }
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
    closeMysqlBtn.addEventListener('click', closeMysqlPanel);
    closeSshBtn.addEventListener('click', closeSshPanel);
    closeEnvBtn.addEventListener('click', closeEnvPanel);
    closeProgressBtn.addEventListener('click', closeProgressPanel);
    closeLogBtn.addEventListener('click', closeLogPanel);
    sshCopyUserBtn.addEventListener('click', async () => {
      const user = sshDetails.querySelector('code');
      if (!user || !user.textContent) return;
      await navigator.clipboard.writeText(user.textContent);
      showMessage(sshFlash, 'SSH user copied');
    });
    sshCopyPassBtn.addEventListener('click', async () => {
      const codes = Array.from(sshDetails.querySelectorAll('code')).map((el) => el.textContent || '');
      const pass = codes[1] || '';
      if (!pass) return;
      await navigator.clipboard.writeText(pass);
      showMessage(sshFlash, 'SSH password copied');
    });
    sshCopyAllBtn.addEventListener('click', async () => {
      const codes = Array.from(sshDetails.querySelectorAll('code')).map((el) => el.textContent || '');
      const text = [
        \`user=\${codes[0] || ''}\`,
        \`password=\${codes[1] || ''}\`,
        \`home=\${codes[2] || ''}\`,
        \`host=\${codes[3] || ''}\`,
        \`port=\${codes[4] || ''}\`,
      ].join('\\n');
      await navigator.clipboard.writeText(text);
      showMessage(sshFlash, 'SSH details copied');
    });
    logOutBtn.addEventListener('click', async () => {
      if (!currentLogRef) return;
      currentLogType = 'out';
      try {
        await loadLog(currentLogRef, currentLogType);
      } catch (error) {
        showMessage(logFlash, error.message, false);
      }
    });
    logErrBtn.addEventListener('click', async () => {
      if (!currentLogRef) return;
      currentLogType = 'error';
      try {
        await loadLog(currentLogRef, currentLogType);
      } catch (error) {
        showMessage(logFlash, error.message, false);
      }
    });
    logRefreshBtn.addEventListener('click', async () => {
      if (!currentLogRef) return;
      try {
        await loadLog(currentLogRef, currentLogType);
      } catch (error) {
        showMessage(logFlash, error.message, false);
      }
    });
    logClearOutBtn.addEventListener('click', async () => {
      if (!currentLogRef) return;
      logClearOutBtn.disabled = true;
      try {
        await clearLog(currentLogRef, 'out');
      } catch (error) {
        showMessage(logFlash, error.message, false);
      } finally {
        logClearOutBtn.disabled = false;
      }
    });
    logClearErrBtn.addEventListener('click', async () => {
      if (!currentLogRef) return;
      logClearErrBtn.disabled = true;
      try {
        await clearLog(currentLogRef, 'error');
      } catch (error) {
        showMessage(logFlash, error.message, false);
      } finally {
        logClearErrBtn.disabled = false;
      }
    });
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

    document.addEventListener('click', async (event) => {
      const btn = event.target.closest('button[data-action="mysql"]');
      if (!btn) return;
      const ref = btn.dataset.ref;
      if (!ref) return;
      btn.disabled = true;
      try {
        await loadMysql(ref);
      } catch (error) {
        showMessage(mysqlFlash, error.message, false);
        mysqlPanel.hidden = false;
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

    mysqlSaveBtn.addEventListener('click', async () => {
      if (!currentMysqlRef) return;
      mysqlSaveBtn.disabled = true;
      try {
        await saveMysql(currentMysqlRef, mysqlIpsInput.value.trim());
      } catch (error) {
        showMessage(mysqlFlash, error.message, false);
        mysqlPanel.hidden = false;
      } finally {
        mysqlSaveBtn.disabled = false;
      }
    });

    document.getElementById('installBtn').addEventListener('click', async () => {
      const payload = {
        repo: document.getElementById('repo').value.trim(),
        domain: document.getElementById('domain').value.trim(),
        branch: document.getElementById('branch').value.trim(),
        pm2Name: document.getElementById('pm2Name').value.trim(),
        port: document.getElementById('port').value.trim(),
        dbMachineId: dbMachineSelect ? dbMachineSelect.value : '${LOCAL_DB_MACHINE_ID}',
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

    if (toggleAccessPasswordBtn) {
      toggleAccessPasswordBtn.addEventListener('click', () => {
        const input = document.getElementById('accessPassword');
        if (!input) return;
        const showing = input.type === 'text';
        input.type = showing ? 'password' : 'text';
        toggleAccessPasswordBtn.textContent = showing ? '👁' : '🙈';
        toggleAccessPasswordBtn.setAttribute('aria-label', showing ? 'Show password' : 'Hide password');
      });
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

function clearLogFile(filePath) {
  if (!filePath) return false;
  if (!fs.existsSync(filePath)) {
    fs.writeFileSync(filePath, '');
    return true;
  }
  fs.truncateSync(filePath, 0);
  return true;
}

async function handleRequest(req, res) {
  if (!requireAuth(req, res)) return;

  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const pathname = url.pathname.replace(/\/+$/, '') || '/';

  try {
    if (req.method === 'GET' && (pathname === '/vault' || pathname === '/manage/vault')) {
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store',
      });
      res.end(renderVaultPage());
      return;
    }

    if (req.method === 'GET' && (pathname === '/db-machines' || pathname === '/manage/db-machines')) {
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store',
      });
      res.end(renderDbMachinesPage());
      return;
    }

    if (req.method === 'GET' && (pathname === '/ssh-keys' || pathname === '/manage/ssh-keys')) {
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store',
      });
      res.end(renderSshKeysPage());
      return;
    }

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

    if (pathname === '/api/db-machines') {
      if (req.method === 'GET') {
        sendJson(res, 200, { machines: readDbMachines() });
        return;
      }

      if (req.method === 'POST') {
        const body = await readBody(req);
        const machine = saveDbMachine(body || {});
        sendJson(res, 200, {
          ok: true,
          message: `Saved DB machine ${machine.name}`,
          machine,
          machines: readDbMachines(),
        });
        return;
      }
    }

    if (pathname === '/api/ssh-keys') {
      if (req.method === 'GET') {
        sendJson(res, 200, { keys: readSshKeys() });
        return;
      }

      if (req.method === 'POST') {
        const body = await readBody(req);
        const key = createSshKey(body || {});
        sendJson(res, 200, {
          ok: true,
          message: `Created SSH key ${key.name}`,
          key,
          keys: readSshKeys(),
        });
        return;
      }
    }

    const sshKeyMatch = pathname.match(/^\/api\/ssh-keys\/(.+)$/);
    if (sshKeyMatch && req.method === 'POST') {
      const keyId = decodeURIComponent(sshKeyMatch[1]);
      const body = await readBody(req);
      const memo = String(body.memo || '').trim();
      const name = String(body.name || '').trim();
      const updated = saveSshKeyMemo({ id: keyId, memo, name });
      sendJson(res, 200, {
        ok: true,
        message: `Saved memo for ${updated.name}`,
        key: updated,
        keys: readSshKeys(),
      });
      return;
    }

    const dbMachineDeleteMatch = pathname.match(/^\/api\/db-machines\/(.+)$/);
    if (dbMachineDeleteMatch && req.method === 'DELETE') {
      deleteDbMachine(decodeURIComponent(dbMachineDeleteMatch[1]));
      sendJson(res, 200, { ok: true, message: 'DB machine deleted', machines: readDbMachines() });
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
      if (body.dbMachineId) args.push('--db-machine', String(body.dbMachineId).trim());
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

    const mysqlMatch = pathname.match(/^\/api\/projects\/(.+?)\/mysql$/);
    if (mysqlMatch) {
      const ref = decodeURIComponent(mysqlMatch[1]);
      const meta = parseEnvFile(metaPathForRef(ref));
      const projectPath = meta.APP_DIR || '';
      const { files, db } = pickDbDetails(projectPath);
      const dbUser = db.DB_USER || db.MYSQL_USER || db.POSTGRES_USER || '';
      const dbName = db.DB_NAME || db.DB_DATABASE || db.MYSQL_DATABASE || db.POSTGRES_DB || '';
      const dbPassword = db.DB_PASSWORD || db.MYSQL_PASSWORD || db.POSTGRES_PASSWORD || '';
      const allowedIps = meta.MYSQL_ALLOWED_IPS || '';
      const projectMachineId = meta.DB_MACHINE_ID || LOCAL_DB_MACHINE_ID;
      const accounts = readMysqlAccounts(dbUser, projectMachineId);
      const machines = readDbMachines();

      if (req.method === 'GET') {
        sendJson(res, 200, {
          project: meta.APP_DOMAIN || meta.PROJECT_SLUG || ref,
          files,
          db,
          dbName,
          dbUser,
          dbPassword,
          allowedIps,
          dbMachineId: projectMachineId,
          machines,
          accounts,
        });
        return;
      }

      if (req.method === 'POST') {
        const body = await readBody(req);
        const ips = String(body.ips || '').trim();
        const machineId = String(body.machineId || projectMachineId || LOCAL_DB_MACHINE_ID).trim();
        const args = ['mysql'];
        if (machineId) args.push('--machine', machineId);
        args.push('--ips', ips, ref);
        const output = runProjectCtl(args);
        const refreshedMeta = parseEnvFile(metaPathForRef(ref));
        const refreshedDb = pickDbDetails(projectPath).db;
        sendJson(res, 200, {
          ok: true,
          message: output || 'MySQL permissions updated',
          project: meta.APP_DOMAIN || meta.PROJECT_SLUG || ref,
          files,
          db: refreshedDb,
          dbName: refreshedDb.DB_NAME || refreshedDb.DB_DATABASE || refreshedDb.MYSQL_DATABASE || refreshedDb.POSTGRES_DB || '',
          dbUser: refreshedDb.DB_USER || refreshedDb.MYSQL_USER || refreshedDb.POSTGRES_USER || '',
          dbPassword: refreshedDb.DB_PASSWORD || refreshedDb.MYSQL_PASSWORD || refreshedDb.POSTGRES_PASSWORD || '',
          allowedIps: refreshedMeta.MYSQL_ALLOWED_IPS || ips,
          dbMachineId: refreshedMeta.DB_MACHINE_ID || projectMachineId || LOCAL_DB_MACHINE_ID,
          machines: readDbMachines(),
          accounts: readMysqlAccounts(refreshedDb.DB_USER || refreshedDb.MYSQL_USER || refreshedDb.POSTGRES_USER || '', refreshedMeta.DB_MACHINE_ID || machineId || projectMachineId),
        });
        return;
      }
    }

    const sshMatch = pathname.match(/^\/api\/projects\/(.+?)\/ssh$/);
    if (sshMatch) {
      const ref = decodeURIComponent(sshMatch[1]);
      const meta = parseEnvFile(metaPathForRef(ref));
      sendJson(res, 200, {
        project: meta.APP_DOMAIN || meta.PROJECT_SLUG || ref,
        user: meta.SSH_UPLOAD_USER || '',
        password: meta.SSH_UPLOAD_PASSWORD || '',
        home: meta.APP_DIR || '',
        host: (req.headers.host || '').replace(/:\d+$/, ''),
        port: '22',
        mode: 'sftp-only',
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

    const updateStreamMatch = pathname.match(/^\/api\/projects\/(.+?)\/update-stream$/);
    if (updateStreamMatch) {
      const ref = decodeURIComponent(updateStreamMatch[1]);
      if (req.method !== 'POST') {
        res.writeHead(405, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('Method not allowed');
        return;
      }
      streamProjectCtl(res, ['update', ref]);
      return;
    }

    const logClearMatch = pathname.match(/^\/api\/projects\/(.+?)\/logs\/clear$/);
    if (logClearMatch) {
      const ref = decodeURIComponent(logClearMatch[1]);
      if (req.method !== 'POST') {
        res.writeHead(405, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('Method not allowed');
        return;
      }

      const body = await readBody(req);
      const type = String(body.type || 'out');
      const meta = parseEnvFile(metaPathForRef(ref));
      const pm2Name = meta.PM2_NAME || slugFromRef(ref);
      const target = getPm2List().find((proc) => (proc?.name || proc?.pm2_env?.name) === pm2Name);
      const outLog = target?.pm2_env?.pm_out_log_path || '';
      const errLog = target?.pm2_env?.pm_err_log_path || '';

      if (type === 'all') {
        clearLogFile(outLog);
        clearLogFile(errLog);
      } else if (type === 'error' || type === 'err') {
        clearLogFile(errLog);
      } else {
        clearLogFile(outLog);
      }

      sendJson(res, 200, { ok: true, message: `${ref} log(s) cleared` });
      return;
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
    if (res.headersSent || res.writableEnded) {
      console.error('[manage] late request failure', error);
      return;
    }
    sendJson(res, 500, { error: error.message || String(error) });
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`manage server listening on 127.0.0.1:${PORT}`);
});
