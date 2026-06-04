import http from 'http';
import { URL } from 'url';

const port = Number(process.env.PORT || 3000);
const quizTitle = process.env.QUIZ_TITLE || "Light No-DB App";
const quiz = [
  {
    "id": "install",
    "question": "Did Multidev install the app?",
    "answers": [
      "yes",
      "no"
    ],
    "correct": "yes"
  },
  {
    "id": "port",
    "question": "Is the runtime using the assigned port?",
    "answers": [
      "yes",
      "no"
    ],
    "correct": "yes"
  },
  {
    "id": "db",
    "question": "Is the DB wiring visible in env?",
    "answers": [
      "yes",
      "no",
      "n/a"
    ],
    "correct": "n/a"
  }
];

function envSummary() {
  return {
    PORT: process.env.PORT || '',
    APP_PORT: process.env.APP_PORT || '',
    GUI_PORT: process.env.GUI_PORT || '',
    API_PORT: process.env.API_PORT || '',
    DB_MACHINE_ID: process.env.DB_MACHINE_ID || '',
    DB_HOST: process.env.DB_HOST || '',
    DB_PORT: process.env.DB_PORT || '',
    MYSQL_HOST: process.env.MYSQL_HOST || '',
    MYSQL_PORT: process.env.MYSQL_PORT || '',
    ACTIVE_CONNECTOR: process.env.ACTIVE_CONNECTOR || '',
    PUBLIC_URL: process.env.PUBLIC_URL || '',
    API_BASE_URL: process.env.API_BASE_URL || '',
  };
}

function htmlPage() {
  const env = envSummary();
  const quizRows = quiz.map((q) => `<p><strong>${q.question}</strong><br>${q.answers.map((a) => `<label><input type="radio" name="${q.id}" value="${a}"> ${a}</label>`).join('<br>')}</p>`).join('');
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${quizTitle}</title><style>body{font-family:system-ui,sans-serif;max-width:900px;margin:40px auto;padding:0 20px;line-height:1.5}code,pre{background:#f5f5f5;padding:2px 5px;border-radius:4px}.card{border:1px solid #ddd;border-radius:12px;padding:16px;margin:16px 0}</style></head><body><h1>${quizTitle}</h1><p>Sample: Light No-DB App</p><div class="card"><h2>Config</h2><pre>${JSON.stringify(env, null, 2)}</pre></div><div class="card"><h2>Quiz</h2>${quizRows}<button onclick="grade()">Grade</button><pre id="out"></pre></div><script>async function grade(){const answers={};document.querySelectorAll('input[type=radio]:checked').forEach(i=>answers[i.name]=i.value);const res=await fetch('/api/quiz/grade',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({answers})});document.getElementById('out').textContent=JSON.stringify(await res.json(),null,2);}</script></body></html>`;
}

function grade(answers = {}) {
  const score = quiz.reduce((acc, item) => acc + (answers[item.id] === item.correct ? 1 : 0), 0);
  return { ok: true, title: quizTitle, score, total: quiz.length };
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (url.pathname === '/api/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, name: "light-no-db", port }));
    return;
  }
  if (url.pathname === '/api/quiz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, quiz }));
    return;
  }
  if (url.pathname === '/api/quiz/grade' && req.method === 'POST') {
    let body = '';
    req.on('data', (chunk) => (body += chunk));
    req.on('end', () => {
      try {
        const parsed = JSON.parse(body || '{}');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(grade(parsed.answers || {})));
      } catch (err) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: String(err.message || err) }));
      }
    });
    return;
  }
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(htmlPage());
});

server.listen(port, () => console.log(`${quizTitle} listening on http://127.0.0.1:${port}`));
