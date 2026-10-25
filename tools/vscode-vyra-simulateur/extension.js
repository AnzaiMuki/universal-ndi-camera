// VYRA Simulateur iPhone : récupère la compilation simulateur du CI (workflow ios-simulateur.yml),
// l'envoie à Appetize.io et affiche le simulateur interactif dans un panneau VS Code.
// Prérequis : `gh` connecté au dépôt, une clé d'API Appetize (gardée dans le coffre de VS Code).
const vscode = require('vscode');
const { execFile } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const WORKFLOW = 'ios-simulateur.yml';
const ARTEFACT = 'VyraCamera-simulateur';
const SUIVI_MS = 90_000;

let panel = null;
let suivi = null;
let occupe = false;

function config() {
  const c = vscode.workspace.getConfiguration('vyraSimulateur');
  return { depot: c.get('depot'), branche: c.get('branche'), appareil: c.get('appareil'), suivreCI: c.get('suivreCI') };
}

function gh(args) {
  return new Promise((resolve, reject) => {
    execFile('gh', args, { maxBuffer: 16 * 1024 * 1024, windowsHide: true }, (err, stdout, stderr) => {
      if (err) reject(new Error((stderr || err.message).trim()));
      else resolve(stdout);
    });
  });
}

async function derniereCompilation(c) {
  const out = await gh(['run', 'list', '-R', c.depot, '--workflow', WORKFLOW, '--branch', c.branche,
    '--status', 'success', '--limit', '1', '--json', 'databaseId,headSha']);
  return JSON.parse(out)[0] || null;
}

async function lancerCompilation(c, progress) {
  const avant = JSON.parse(await gh(['run', 'list', '-R', c.depot, '--workflow', WORKFLOW,
    '--limit', '1', '--json', 'databaseId']))[0];
  await gh(['workflow', 'run', WORKFLOW, '-R', c.depot, '--ref', c.branche]);
  progress.report({ message: 'compilation lancée sur le Mac du CI…' });
  let id = null;
  for (let i = 0; i < 30 && !id; i++) {
    await new Promise(r => setTimeout(r, 4000));
    const r = JSON.parse(await gh(['run', 'list', '-R', c.depot, '--workflow', WORKFLOW,
      '--limit', '1', '--json', 'databaseId']))[0];
    if (r && (!avant || r.databaseId !== avant.databaseId)) id = r.databaseId;
  }
  if (!id) throw new Error('la compilation ne démarre pas sur GitHub');
  progress.report({ message: 'compilation en cours (≈ 5 min)…' });
  await gh(['run', 'watch', String(id), '-R', c.depot, '--exit-status', '--interval', '20']);
  return { databaseId: id };
}

async function cleAppetize(context, demander) {
  let cle = await context.secrets.get('appetize');
  if (!cle || demander) {
    cle = await vscode.window.showInputBox({
      title: "Clé d'API Appetize", prompt: 'appetize.io ▸ Account ▸ API token', password: true, ignoreFocusOut: true,
    });
    if (!cle) throw new Error("clé d'API Appetize manquante");
    await context.secrets.store('appetize', cle);
  }
  return cle;
}

async function envoyerAppetize(context, run, c, progress) {
  progress.report({ message: 'téléchargement de la compilation…' });
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vyra-simu-'));
  try {
    await gh(['run', 'download', String(run.databaseId), '-R', c.depot, '-n', ARTEFACT, '-D', dir]);
    const zip = path.join(dir, 'VyraCamera-simulateur.zip');
    progress.report({ message: 'envoi à Appetize…' });
    const cle = await cleAppetize(context, false);
    const form = new FormData();
    form.append('platform', 'ios');
    form.append('file', new Blob([fs.readFileSync(zip)]), 'VyraCamera-simulateur.zip');
    const existante = context.globalState.get('publicKey');
    const url = 'https://api.appetize.io/v1/apps' + (existante ? '/' + existante : '');
    const rep = await fetch(url, { method: 'POST', headers: { 'X-API-KEY': cle }, body: form });
    if (rep.status === 401 || rep.status === 403) {
      await context.secrets.delete('appetize');
      throw new Error("clé d'API Appetize refusée");
    }
    if (!rep.ok) throw new Error(`Appetize : ${rep.status} ${await rep.text()}`);
    const { publicKey } = await rep.json();
    await context.globalState.update('publicKey', publicKey);
    await context.globalState.update('runId', run.databaseId);
    return publicKey;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function afficher(publicKey, c) {
  const src = `https://appetize.io/embed/${publicKey}?device=${encodeURIComponent(c.appareil)}` +
    `&orientation=landscape&scale=auto&centered=both&autoplay=true&t=${Date.now()}`;
  if (!panel) {
    panel = vscode.window.createWebviewPanel('vyraSimulateur', 'iPhone · VYRA Camera',
      vscode.ViewColumn.Beside, { retainContextWhenHidden: true });
    panel.onDidDispose(() => { panel = null; clearInterval(suivi); suivi = null; });
  }
  panel.webview.html = `<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; frame-src https://appetize.io; style-src 'unsafe-inline';">
<style>html,body{margin:0;height:100%;background:#0b0f14}iframe{border:0;width:100%;height:100%}</style></head>
<body><iframe src="${src}" allow="autoplay; clipboard-read; clipboard-write; microphone"></iframe></body></html>`;
  panel.reveal(vscode.ViewColumn.Beside, true);
}

async function mettreAJour(context, { recompiler }) {
  if (occupe) return;
  occupe = true;
  const c = config();
  try {
    await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: 'VYRA Simulateur' },
      async progress => {
        progress.report({ message: 'recherche de la dernière compilation…' });
        let run = recompiler ? null : await derniereCompilation(c);
        if (!run) run = await lancerCompilation(c, progress);
        let key = context.globalState.get('publicKey');
        if (!key || context.globalState.get('runId') !== run.databaseId) {
          key = await envoyerAppetize(context, run, c, progress);
        }
        afficher(key, c);
      });
    if (c.suivreCI && !suivi) suivi = setInterval(() => suivreCI(context), SUIVI_MS);
  } catch (e) {
    vscode.window.showErrorMessage('VYRA Simulateur : ' + e.message);
  } finally {
    occupe = false;
  }
}

// Temps réel : dès qu'une nouvelle compilation réussit (push sous ios/), le panneau se recharge.
async function suivreCI(context) {
  if (occupe || !panel) return;
  const c = config();
  try {
    const run = await derniereCompilation(c);
    if (!run || run.databaseId === context.globalState.get('runId')) return;
    occupe = true;
    const key = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Window, title: 'VYRA : nouvelle compilation' },
      progress => envoyerAppetize(context, run, c, progress));
    afficher(key, c);
    vscode.window.setStatusBarMessage('VYRA : simulateur mis à jour (' + run.headSha.slice(0, 7) + ')', 8000);
  } catch (e) {
    console.error('[vyra-simulateur]', e);
  } finally {
    occupe = false;
  }
}

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand('vyraSimulateur.ouvrir', () => mettreAJour(context, { recompiler: false })),
    vscode.commands.registerCommand('vyraSimulateur.recompiler', () => mettreAJour(context, { recompiler: true })),
    vscode.commands.registerCommand('vyraSimulateur.cle', () => cleAppetize(context, true).catch(() => {})),
    { dispose: () => clearInterval(suivi) },
  );
}

module.exports = { activate, deactivate() {} };
