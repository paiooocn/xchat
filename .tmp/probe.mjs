import { readFileSync } from 'fs';
import { JSDOM, VirtualConsole } from 'jsdom';

const ROOT = '/mnt/kd/dop/pcr/aicoding/xchat/assets/web';
const html = readFileSync(`${ROOT}/index.html`, 'utf8');
const errors = [];
const vc = new VirtualConsole();
vc.on('jsdomError', e => errors.push('jsdomError: ' + e.message + '\n' + (e.detail?.stack || '')));
vc.on('error', e => errors.push('error: ' + e));
vc.on('log', (...a) => console.log('[page log]', ...a));
vc.on('warn', (...a) => console.log('[page warn]', ...a));

const dom = new JSDOM(html, {
  runScripts: 'dangerously',
  resources: 'usable',
  url: 'file://' + ROOT + '/',
  virtualConsole: vc,
  contentType: 'text/html',
});
await new Promise(r => setTimeout(r, 800));
const doc = dom.window.document;
console.log('ready=', doc.readyState);
console.log('bodyChars=', (doc.body?.innerText || '').length);
console.log('app html len=', doc.getElementById('app')?.innerHTML?.length || 0);
console.log('window.Router=', typeof dom.window.Router);
console.log('=== errors ===');
errors.forEach((e, i) => console.log(`#${i}\n${e}\n`));
