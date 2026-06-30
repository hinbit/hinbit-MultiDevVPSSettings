import fs from 'fs';
import path from 'path';

const root = path.resolve(process.cwd());
const samplesDir = path.join(root, 'samples');
const docsDir = path.join(root, 'docs');

const apps = [
  {
    slug: 'ui-control',
    title: 'UI Control Service',
    description: 'A service-only app with a browser UI. No DB machine is required.',
    kind: 'ui-only',
    examplePort: 3000,
    hasDb: false,
    hasConnector: false,
    envExample: [
      '# Main runtime port for the single process.',
      "PORT='3000'",
      '',
      '# Public URL used by the browser UI.',
      "PUBLIC_URL='https://ui-control.example.com'",
      '',
      '# Optional webhook token.',
      "WEBHOOK_TOKEN='change_me'",
      '',
      '# No DB variables are required for this template.',
    ],
    runEnvExample: [
      "PORT='3000'",
      "PUBLIC_URL='http://localhost:3000'",
      "WEBHOOK_TOKEN='quiz-secret'",
      "QUIZ_TITLE='UI Control Smoke Test'",
    ],
  },
  {
    slug: 'light-no-db',
    title: 'Light No-DB App',
    description: 'A very light app with no database dependency.',
    kind: 'light',
    examplePort: 3001,
    hasDb: false,
    hasConnector: false,
    envExample: [
      '# Single runtime port.',
      "PORT='3001'",
      '',
      '# Optional public URL.',
      "PUBLIC_URL='https://light-no-db.example.com'",
      '',
      '# Optional API base URL.',
      "API_BASE_URL='https://light-no-db.example.com/api'",
      '',
      '# Optional webhook token.',
      "WEBHOOK_TOKEN='change_me'",
      '',
      '# No DB settings required.',
    ],
    runEnvExample: [
      "PORT='3001'",
      "PUBLIC_URL='http://localhost:3001'",
      "API_BASE_URL='http://localhost:3001/api'",
      "WEBHOOK_TOKEN='quiz-secret'",
      "QUIZ_TITLE='Light No-DB Smoke Test'",
    ],
  },
  {
    slug: 'local-db',
    title: 'Local DB App',
    description: 'An app that uses the local MySQL instance on the same VPS.',
    kind: 'local-db',
    examplePort: 3002,
    hasDb: true,
    hasConnector: false,
    envExample: [
      '# Main app port.',
      "PORT='3002'",
      '',
      '# Local DB machine on the same VPS.',
      "DB_MACHINE_ID='local-current'",
      "DB_HOST='127.0.0.1'",
      "DB_PORT='3306'",
      "MYSQL_HOST='127.0.0.1'",
      "MYSQL_PORT='3306'",
      "DB_NAME='local_db_demo'",
      "DB_USER='local_db_demo'",
      "DB_PASSWORD='change_me'",
      "MYSQL_DATABASE='local_db_demo'",
      "MYSQL_USER='local_db_demo'",
      "MYSQL_PASSWORD='change_me'",
      '',
      '# Public URL and API base.',
      "PUBLIC_URL='https://local-db.example.com'",
      "API_BASE_URL='https://local-db.example.com/api'",
      '',
      '# Optional webhook token.',
      "WEBHOOK_TOKEN='change_me'",
    ],
    runEnvExample: [
      "PORT='3002'",
      "DB_MACHINE_ID='local-current'",
      "DB_HOST='127.0.0.1'",
      "DB_PORT='3306'",
      "MYSQL_HOST='127.0.0.1'",
      "MYSQL_PORT='3306'",
      "DB_NAME='quiz_local_db'",
      "DB_USER='quiz_local_db'",
      "DB_PASSWORD='quiz-secret'",
      "MYSQL_DATABASE='quiz_local_db'",
      "MYSQL_USER='quiz_local_db'",
      "MYSQL_PASSWORD='quiz-secret'",
      "PUBLIC_URL='http://localhost:3002'",
      "API_BASE_URL='http://localhost:3002/api'",
      "WEBHOOK_TOKEN='quiz-secret'",
      "QUIZ_TITLE='Local DB Smoke Test'",
    ],
  },
  {
    slug: 'remote-connector',
    title: 'Remote DB + Connector App',
    description: 'An app that uses a remote DB machine and an outbound connector such as 360dialog or Twilio.',
    kind: 'remote-db-connector',
    examplePort: 3003,
    hasDb: true,
    hasConnector: true,
    envExample: [
      '# Main app port.',
      "PORT='3003'",
      '',
      '# Remote DB machine details.',
      "DB_MACHINE_ID='seach-db'",
      "DB_HOST='127.0.0.1'",
      "DB_PORT='3307'",
      "MYSQL_HOST='127.0.0.1'",
      "MYSQL_PORT='3307'",
      "DB_NAME='remote_connector_demo'",
      "DB_USER='remote_connector_demo'",
      "DB_PASSWORD='change_me'",
      "MYSQL_DATABASE='remote_connector_demo'",
      "MYSQL_USER='remote_connector_demo'",
      "MYSQL_PASSWORD='change_me'",
      '',
      '# Connector / external API layer.',
      "ACTIVE_CONNECTOR='dialog360'",
      "DIALOG360_API_KEY='change_me'",
      "DIALOG360_DRY_RUN='1'",
      "TWILIO_ACCOUNT_SID='change_me'",
      "TWILIO_AUTH_TOKEN='change_me'",
      '',
      '# Public URL and API base.',
      "PUBLIC_URL='https://remote-connector.example.com'",
      "API_BASE_URL='https://remote-connector.example.com/api'",
      '',
      '# Optional webhook token.',
      "WEBHOOK_TOKEN='change_me'",
    ],
    runEnvExample: [
      "PORT='3003'",
      "DB_MACHINE_ID='seach-db'",
      "DB_HOST='127.0.0.1'",
      "DB_PORT='3307'",
      "MYSQL_HOST='127.0.0.1'",
      "MYSQL_PORT='3307'",
      "DB_NAME='quiz_remote_connector'",
      "DB_USER='quiz_remote_connector'",
      "DB_PASSWORD='quiz-secret'",
      "MYSQL_DATABASE='quiz_remote_connector'",
      "MYSQL_USER='quiz_remote_connector'",
      "MYSQL_PASSWORD='quiz-secret'",
      "ACTIVE_CONNECTOR='dialog360'",
      "DIALOG360_API_KEY='quiz-secret'",
      "DIALOG360_DRY_RUN='0'",
      "TWILIO_ACCOUNT_SID='quiz-secret'",
      "TWILIO_AUTH_TOKEN='quiz-secret'",
      "PUBLIC_URL='http://localhost:3003'",
      "API_BASE_URL='http://localhost:3003/api'",
      "WEBHOOK_TOKEN='quiz-secret'",
      "QUIZ_TITLE='Remote Connector Smoke Test'",
    ],
  },
];

function lines(items) {
  return `${items.join('\n')}\n`;
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function write(filePath, content) {
  ensureDir(path.dirname(filePath));
  fs.writeFileSync(filePath, content);
}

function templateReadme(app) {
  return lines([
    `# ${app.title} Template`,
    '',
    'This is the installable skeleton version.',
    '',
    '## Purpose',
    '',
    app.description,
    '',
    '## Port glossary',
    '',
    '- `PORT`: primary runtime port for the app process.',
    '- `APP_PORT`: Multidev-assigned app port, if the installer writes one.',
    '- `GUI_PORT`: separate browser UI port when the UI is split from the API.',
    '- `API_PORT`: backend API port when the UI and API are separate processes.',
    '- `DB_HOST` / `DB_PORT`: database host and TCP port.',
    '- `MYSQL_HOST` / `MYSQL_PORT`: MySQL-specific host and port.',
    '- `DB_MACHINE_ID`: Multidev DB machine selection such as `local-current` or `seach-db`.',
    '- `CONNECTOR_PORT`: relay port for external API connectors.',
    '- `ACTIVE_CONNECTOR`: connector selector such as 360dialog or Twilio.',
    '- `WEBHOOK_TOKEN`: auth token for webhook or callback endpoints.',
    '- `PUBLIC_URL` / `API_BASE_URL`: public domain or API base used by the client.',
    '- `PREINSTALL_REQUIREMENTS.md`: OS packages or browser binaries the app needs before startup.',
    '- `start` must launch the long-lived runtime on `PORT`; a build artifact alone is not enough for Multidev.',
    '- ship a health endpoint and make sure the process stays online under PM2 after install/update.',
    '',
    '## Install rule',
    '',
    'Future Codex sessions should copy this template into a real repo, keep the root `package.json` start script visible to Multidev, and make sure env values are complete before install.',
    'Multidev will retry the PM2 restart and the smoke test once, but the app still has to boot successfully under `npm start` or the equivalent root start script.',
    'If the app needs special nginx/path wiring, put it in `VPS-INSTALL.MD` as a JSON block so Multidev can wire it automatically during install/update.',
    'If the app needs OS packages or browser binaries before startup, add them to `PREINSTALL_REQUIREMENTS.md` so Multidev installs them before dependency setup.',
  ]);
}

function preinstallRequirementsDoc(app) {
  return lines([
    `# Preinstall Requirements - ${app.title}`,
    '',
    'Use this file for OS packages or runtime binaries that must exist before Multidev runs dependency install or build.',
    '',
    '```vps-requirements',
    JSON.stringify(
      {
        apt: [],
      },
      null,
      2,
    ),
    '```',
    '',
    'If the app needs Chromium, add `"chromium"` to the `apt` array.',
    'Keep the list empty when no extra system packages are required.',
  ]);
}

function templatePackageJson(app) {
  return `${JSON.stringify(
    {
      name: `${app.slug}-template`,
      version: '1.0.0',
      private: true,
      type: 'module',
      scripts: {
        start: 'node server.js',
        dev: 'node --watch server.js',
        check: 'node --check server.js',
      },
    },
    null,
    2,
  )}\n`;
}

function templateServer(app) {
  const envKeys = [
    'PORT',
    'APP_PORT',
    'GUI_PORT',
    'API_PORT',
    'DB_MACHINE_ID',
    'DB_HOST',
    'DB_PORT',
    'MYSQL_HOST',
    'MYSQL_PORT',
    'DB_NAME',
    'DB_USER',
    'ACTIVE_CONNECTOR',
    'PUBLIC_URL',
    'API_BASE_URL',
  ];
  const source = lines([
    "import http from 'http';",
    "import { URL } from 'url';",
    '',
    'const port = Number(process.env.PORT || 3000);',
    `const title = process.env.APP_TITLE || ${JSON.stringify(app.title)};`,
    `const envKeys = ${JSON.stringify(envKeys, null, 2)};`,
    '',
    'function envSummary() {',
    '  return envKeys.reduce((acc, key) => {',
    "    acc[key] = process.env[key] || '';",
    '    return acc;',
    '  }, {});',
    '}',
    '',
    'function htmlPage() {',
    '  const env = envSummary();',
    "  return `<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>${title}</title><style>body{font-family:system-ui,sans-serif;max-width:900px;margin:40px auto;padding:0 20px;line-height:1.5}code,pre{background:#f5f5f5;padding:2px 5px;border-radius:4px}.card{border:1px solid #ddd;border-radius:12px;padding:16px;margin:16px 0}</style></head><body><h1>${title}</h1><p>Template skeleton for Multidev install testing.</p><div class=\"card\"><h2>Config</h2><pre>\${JSON.stringify(env, null, 2)}</pre></div><div class=\"card\"><h2>Install contract</h2><p>This repo must keep a root <code>package.json</code> with <code>start</code> so Multidev can detect the runtime without manual rescue.</p></div></body></html>`;",
    '}',
    '',
    'const server = http.createServer((req, res) => {',
    "  const url = new URL(req.url, `http://${req.headers.host}`);",
    "  if (url.pathname === '/api/health') {",
    "    res.writeHead(200, { 'Content-Type': 'application/json' });",
    `    res.end(JSON.stringify({ ok: true, name: ${JSON.stringify(app.slug)}, port }));`,
    '    return;',
    '  }',
    "  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });",
    '  res.end(htmlPage());',
    '});',
    '',
    "server.listen(port, () => console.log(`${title} listening on http://127.0.0.1:${port}`));",
  ]);
  return source;
}

function vpsInstallDoc(app, runnable = false) {
  const routes = [];
  if (app.slug === 'remote-connector') {
    routes.push(
      { path: '/upload_media', port: 8787, type: 'prefix' },
      { path: '/media/save', port: 8787, type: 'prefix' },
      { path: '/api/commands/next', port: 8787, type: 'prefix' },
    );
  }
  if (app.slug === 'ui-control') {
    routes.push({ path: '/api', port: app.examplePort, type: 'prefix' });
  }

  const runtimePort = runnable ? app.examplePort + 5000 : app.examplePort;
  const body = [
    `# VPS Install Notes - ${app.title}${runnable ? ' 2run' : ''}`,
    '',
    'This file is the Multidev install contract for the app.',
    '',
    '## What Multidev should look for',
    '',
    '- root scripts in `package.json`',
    '- complete env templates, including empty keys',
    '- optional extra nginx route hints',
    '- optional DB / connector wiring',
    '',
    '## Route hints',
    '',
    'If the app exposes extra HTTP routes that need to be served by nginx on a different upstream port, keep them in the JSON block below.',
    'Multidev will look for this file during install and update, and will wire the routes automatically when the block is present.',
    '',
    '```vps-install',
    JSON.stringify(
      {
        proxy_routes: routes,
      },
      null,
      2,
    ),
    '```',
    '',
    '## Notes',
    '',
    `- main runtime port example: ${runtimePort}`,
    '- keep `PORT`, `APP_PORT`, `GUI_PORT`, `API_PORT`, `DB_*`, `MYSQL_*`, `CONNECTOR_*`, `PUBLIC_URL`, and `API_BASE_URL` in the env template when relevant',
    '- use `server/.env`, `client/.env`, or `dashboard/.env` if the repo has split runtime files',
    '- use `PREINSTALL_REQUIREMENTS.md` for OS packages or browser binaries such as Chromium',
    '- make sure the root runtime process stays alive under PM2; a successful build does not create a service by itself',
    '- add a `/health` or `/api/health` route so Multidev smoke tests can confirm the domain serves the same app as the local port',
    '- do not hardcode localhost ports into the browser bundle',
  ];
  return lines(body);
}

function runReadme(app) {
  return lines([
    `# ${app.title} 2run`,
    '',
    'This is the runnable smoke-test copy of the template.',
    '',
    '## What it does',
    '',
    '- serves a small quiz UI',
    '- exposes `/api/health`',
    '- exposes `/api/quiz`',
    '- exposes `/api/quiz/grade`',
    '',
    '## Why it exists',
    '',
    'This copy is meant to validate that Multidev can install, start, map ports, and serve the app end to end.',
    '',
    '## Ports',
    '',
    'Use the generated `PORT` from Multidev. The sample runs on that port and should not be hardcoded to localhost:3001.',
    '',
    '## Install hints',
    '',
    'The sample also includes `VPS-INSTALL.MD` so Multidev can learn about extra nginx route wiring when it exists.',
    'If the sample ever needs a browser or OS package, `PREINSTALL_REQUIREMENTS.md` is where that requirement belongs.',
    'If the sample does not keep a real runtime process alive under PM2, the domain can map correctly and still return 502.',
  ]);
}

function quizServer(app) {
  const quizJson = JSON.stringify(
    [
      { id: 'install', question: 'Did Multidev install the app?', answers: ['yes', 'no'], correct: 'yes' },
      { id: 'port', question: 'Is the runtime using the assigned port?', answers: ['yes', 'no'], correct: 'yes' },
      { id: 'db', question: 'Is the DB wiring visible in env?', answers: ['yes', 'no', 'n/a'], correct: app.hasDb ? 'yes' : 'n/a' },
    ],
    null,
    2,
  );

  const source = lines([
    "import http from 'http';",
    "import { URL } from 'url';",
    '',
    'const port = Number(process.env.PORT || 3000);',
    `const quizTitle = process.env.QUIZ_TITLE || ${JSON.stringify(app.title)};`,
    `const quiz = ${quizJson};`,
    '',
    'function envSummary() {',
    '  return {',
    "    PORT: process.env.PORT || '',",
    "    APP_PORT: process.env.APP_PORT || '',",
    "    GUI_PORT: process.env.GUI_PORT || '',",
    "    API_PORT: process.env.API_PORT || '',",
    "    DB_MACHINE_ID: process.env.DB_MACHINE_ID || '',",
    "    DB_HOST: process.env.DB_HOST || '',",
    "    DB_PORT: process.env.DB_PORT || '',",
    "    MYSQL_HOST: process.env.MYSQL_HOST || '',",
    "    MYSQL_PORT: process.env.MYSQL_PORT || '',",
    "    ACTIVE_CONNECTOR: process.env.ACTIVE_CONNECTOR || '',",
    "    PUBLIC_URL: process.env.PUBLIC_URL || '',",
    "    API_BASE_URL: process.env.API_BASE_URL || '',",
    '  };',
    '}',
    '',
    'function htmlPage() {',
    '  const env = envSummary();',
    "  const quizRows = quiz.map((q) => `<p><strong>${q.question}</strong><br>${q.answers.map((a) => `<label><input type=\"radio\" name=\"${q.id}\" value=\"${a}\"> ${a}</label>`).join('<br>')}</p>`).join('');",
    "  return `<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>${quizTitle}</title><style>body{font-family:system-ui,sans-serif;max-width:900px;margin:40px auto;padding:0 20px;line-height:1.5}code,pre{background:#f5f5f5;padding:2px 5px;border-radius:4px}.card{border:1px solid #ddd;border-radius:12px;padding:16px;margin:16px 0}</style></head><body><h1>${quizTitle}</h1><p>Sample: __TITLE__</p><div class=\"card\"><h2>Config</h2><pre>\${JSON.stringify(env, null, 2)}</pre></div><div class=\"card\"><h2>Quiz</h2>${quizRows}<button onclick=\"grade()\">Grade</button><pre id=\"out\"></pre></div><script>async function grade(){const answers={};document.querySelectorAll('input[type=radio]:checked').forEach(i=>answers[i.name]=i.value);const res=await fetch('/api/quiz/grade',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({answers})});document.getElementById('out').textContent=JSON.stringify(await res.json(),null,2);}</script></body></html>`;",
    '}',
    '',
    'function grade(answers = {}) {',
    "  const score = quiz.reduce((acc, item) => acc + (answers[item.id] === item.correct ? 1 : 0), 0);",
    '  return { ok: true, title: quizTitle, score, total: quiz.length };',
    '}',
    '',
    'const server = http.createServer(async (req, res) => {',
    "  const url = new URL(req.url, `http://${req.headers.host}`);",
    "  if (url.pathname === '/api/health') {",
    "    res.writeHead(200, { 'Content-Type': 'application/json' });",
    `    res.end(JSON.stringify({ ok: true, name: ${JSON.stringify(app.slug)}, port }));`,
    '    return;',
    '  }',
    "  if (url.pathname === '/api/quiz') {",
    "    res.writeHead(200, { 'Content-Type': 'application/json' });",
    '    res.end(JSON.stringify({ ok: true, quiz }));',
    '    return;',
    '  }',
    "  if (url.pathname === '/api/quiz/grade' && req.method === 'POST') {",
    "    let body = '';",
    "    req.on('data', (chunk) => (body += chunk));",
    "    req.on('end', () => {",
    '      try {',
    "        const parsed = JSON.parse(body || '{}');",
    "        res.writeHead(200, { 'Content-Type': 'application/json' });",
    '        res.end(JSON.stringify(grade(parsed.answers || {})));',
    '      } catch (err) {',
    "        res.writeHead(400, { 'Content-Type': 'application/json' });",
    "        res.end(JSON.stringify({ ok: false, error: String(err.message || err) }));",
    '      }',
    '    });',
    '    return;',
    '  }',
    "  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });",
    '  res.end(htmlPage());',
    '});',
    '',
    "server.listen(port, () => console.log(`${quizTitle} listening on http://127.0.0.1:${port}`));",
  ]);

  return source.replaceAll('__TITLE__', app.title);
}

function packageJson(app, includeDbScripts) {
  const scripts = {
    start: 'node server.js',
    dev: 'node --watch server.js',
    check: 'node --check server.js',
  };
  if (includeDbScripts) {
    scripts['db:init'] = "node -e \"console.log('db:init placeholder')\"";
    scripts['db:seed'] = "node -e \"console.log('db:seed placeholder')\"";
  }
  return `${JSON.stringify(
    {
      name: `${app.slug}-quiz`,
      version: '1.0.0',
      private: true,
      type: 'module',
      scripts,
    },
    null,
    2,
  )}\n`;
}

function docsReadme() {
  return lines([
    '# Multidev Sample Program Pack',
    '',
    'This pack describes four skeleton application shapes and their runnable `2run_` smoke-test copies.',
    '',
    '## The four sample programs',
    '',
    '1. `ui-control` - service-only app with a browser UI, no DB machine required.',
    '2. `light-no-db` - very light app with no DB dependency.',
    '3. `local-db` - app that uses the local MySQL instance on the VPS.',
    '4. `remote-connector` - app that uses a remote DB machine and an outbound connector layer such as 360dialog or Twilio.',
    '',
    '## How to read the examples',
    '',
    '- `PORT` is the main runtime port Multidev should assign.',
    '- `APP_PORT` is the saved Multidev app port when present.',
    '- `GUI_PORT` is for split UI processes.',
    '- `API_PORT` is for split API processes.',
    '- `DB_HOST` / `DB_PORT` / `MYSQL_HOST` / `MYSQL_PORT` describe database connectivity.',
    '- `CONNECTOR_PORT` is for connector relay services.',
    '- `PUBLIC_URL` / `API_BASE_URL` should point at the installed domain, not localhost.',
    '- `VPS-INSTALL.MD` can hold a JSON route block for extra nginx wiring that should be installed automatically.',
    '- `PREINSTALL_REQUIREMENTS.md` can list OS packages or browser binaries such as Chromium that must exist before install.',
    '',
    '## Install goal',
    '',
    'The idea is to let another Codex session copy one of these skeletons into a real app repo and have Multidev install it in one run without manual rescue.',
    '',
    '## Samples layout',
    '',
    '- `samples/templates/{progname}` = skeleton only',
    '- `samples/2run_{progname}` = runnable quiz smoke test copy',
  ]);
}

for (const app of apps) {
  const templateBase = path.join(samplesDir, 'templates', app.slug);
  const runBase = path.join(samplesDir, `2run_${app.slug}`);

  write(path.join(templateBase, 'README.md'), templateReadme(app));
  write(path.join(templateBase, 'package.json'), templatePackageJson(app));
  write(path.join(templateBase, 'server.js'), templateServer(app));
  write(path.join(templateBase, '.env.example'), lines(app.envExample));
  write(path.join(templateBase, 'PREINSTALL_REQUIREMENTS.md'), preinstallRequirementsDoc(app));
  write(path.join(templateBase, 'VPS-INSTALL.MD'), vpsInstallDoc(app, false));

  write(path.join(runBase, 'README.md'), runReadme(app));
  write(path.join(runBase, '.env.example'), lines(app.runEnvExample));
  write(path.join(runBase, 'PREINSTALL_REQUIREMENTS.md'), preinstallRequirementsDoc(app));
  write(path.join(runBase, 'VPS-INSTALL.MD'), vpsInstallDoc(app, true));
  write(path.join(runBase, 'package.json'), packageJson(app, app.hasDb));
  write(path.join(runBase, 'server.js'), quizServer(app));
}

write(path.join(samplesDir, 'README.md'), docsReadme());
write(
  path.join(docsDir, 'multidev-sample-programs.md'),
  lines([
    '# Multidev Sample Program Pack',
    '',
    'The `samples/` tree contains four skeleton templates and four runnable `2run_` smoke-test copies.',
    '',
    'Use the templates for real app scaffolding, and the `2run_` copies to verify the install path works end to end.',
    '',
    'Every sample also includes `VPS-INSTALL.MD` with a machine-readable route block so Multidev can wire extra nginx paths automatically when needed.',
    'The templates also ship `PREINSTALL_REQUIREMENTS.md` so Multidev can install OS packages or browser binaries before dependency setup when a sample needs them.',
  ]),
);

console.log(`Generated sample templates in ${samplesDir}`);
