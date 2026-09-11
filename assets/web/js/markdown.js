// Markdown 渲染(无外部依赖):
//   标题(H1~H6)、粗体/斜体/行内代码/链接/图片、列表(无序/有序/任务 todo)、
//   引用块、代码块(支持 ```mermaid 占位)、GFM 表格、水平线、换行/段落。
//   扩展: <think>...</think> 折叠块(斜体 muted,默认折叠)。
//   扩展: $...$ / $$...$$ 数学(MarkdownKatex)。
//   扩展: ```mermaid 代码块 → MarkdownMermaid 占位(原文 + 提示)。
window.Markdown = (function () {
  function escape(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  // 1) 抽出 <think>...</think> → 占位
  function extractThinkBlocks(text) {
    const blocks = [];
    const re = /<think>([\s\S]*?)<\/think>/gi;
    let out = '';
    let last = 0;
    let m;
    while ((m = re.exec(text)) !== null) {
      out += text.slice(last, m.index) + `\u0000THINK_${blocks.length}\u0000`;
      blocks.push(m[1]);
      last = re.lastIndex;
    }
    out += text.slice(last);
    return { text: out, blocks };
  }
  // 2) 抽出 ```lang ... ``` 代码块 → 占位(避免内部被 md 规则破坏)
  function extractCodeBlocks(text) {
    const blocks = [];
    const re = /```([a-zA-Z0-9_+-]*)\n?([\s\S]*?)```/g;
    let out = '';
    let last = 0;
    let m;
    while ((m = re.exec(text)) !== null) {
      out += text.slice(last, m.index) + `\u0000CODE_${blocks.length}\u0000\n`;
      blocks.push({ lang: (m[1] || '').toLowerCase(), code: m[2] });
      last = re.lastIndex;
    }
    out += text.slice(last);
    return { text: out, blocks };
  }

  // 行内 markdown(在已 escape 后的字符串上跑)
  function inlineMd(s) {
    // 行内代码: 优先处理,避免内部 * 等被外层规则吞
    s = s.replace(/`([^`\n]+)`/g, (_, c) => `<code>${c}</code>`);
    // 图片: ![alt](url)
    s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)/g, (_, alt, u, t) =>
      `<img src="${escape(u)}" alt="${escape(alt)}" title="${escape(t || '')}" loading="lazy">`);
    // 链接: [text](url)
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, t, u) =>
      `<a href="${escape(u)}" target="_blank" rel="noopener">${t}</a>`);
    // 粗体
    s = s.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
    s = s.replace(/__([^_\n]+)__/g, '<strong>$1</strong>');
    // 斜体
    s = s.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, '$1<em>$2</em>');
    s = s.replace(/(^|[^_])_([^_\n]+)_(?!_)/g, '$1<em>$2</em>');
    return s;
  }

  // 表格解析: 表头 + 分隔 + 行
  function renderTable(headerLine, sepLine, bodyLines) {
    const headers = headerLine.split('|').map((s) => s.trim()).filter((s, i, a) => !(i === 0 && s === '') && !(i === a.length - 1 && s === ''));
    const seps = sepLine.split('|').map((s) => s.trim()).filter(Boolean);
    const aligns = seps.map((s) => {
      const l = s.startsWith(':'); const r = s.endsWith(':');
      if (l && r) return 'center'; if (r) return 'right'; if (l) return 'left'; return 'left';
    });
    const head = headers.map((h, i) => `<th style="text-align:${aligns[i] || 'left'}">${inlineMd(escape(h))}</th>`).join('');
    const body = bodyLines.map((line) => {
      const cells = line.split('|').map((s) => s.trim()).filter((s, i, a) => !(i === 0 && s === '') && !(i === a.length - 1 && s === ''));
      return '<tr>' + cells.map((c, i) => `<td style="text-align:${aligns[i] || 'left'}">${inlineMd(escape(c))}</td>`).join('') + '</tr>';
    }).join('');
    return `<div class="md-table-wrap"><table class="md-table"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
  }

  // 主渲染
  function render(text) {
    if (!text) return '';
    // 0) think 块抽出
    const t1 = extractThinkBlocks(text);
    // 1) 代码块抽出
    const t2 = extractCodeBlocks(t1.text);

    // 2) 行内数学(在原始行上识别 $ ... $)
    // 先按行处理,行内 $...$ 用 MarkdownKatex.apply 渲染。
    // 行间 $$...$$ 整段单行处理。
    // 简化:把数学块临时也抽出成占位。
    const mathBlocks = [];
    let src = t2.text.replace(/\$\$([\s\S]*?)\$\$/g, (_, code) => {
      mathBlocks.push({ display: true, code: code });
      return `\u0000MATH_${mathBlocks.length - 1}\u0000\n`;
    }).replace(/(^|[^$])\$([^$\n]+?)\$(?!\d)/g, (_, pre, code) => {
      mathBlocks.push({ display: false, code: code });
      return `${pre}\u0000MATH_${mathBlocks.length - 1}\u0000`;
    });

    // 3) 按行处理
    const lines = src.split('\n');
    const out = [];
    let i = 0;
    while (i < lines.length) {
      const ln = lines[i];
      // 占位行(代码块 / 思考 / 数学)
      const codePH = ln.match(/^\s*\u0000CODE_(\d+)\u0000\s*$/);
      if (codePH) {
        const blk = t2.blocks[parseInt(codePH[1], 10)];
        if (blk.lang === 'mermaid' && window.MarkdownMermaid) {
          out.push(window.MarkdownMermaid.renderPlaceholder(blk.code));
        } else {
          const langCls = blk.lang ? ` class="lang-${escAttr(blk.lang)}"` : '';
          out.push(`<pre class="md-code"><code${langCls}>${escape(blk.code)}</code></pre>`);
        }
        i++; continue;
      }
      const thinkPH = ln.match(/^\s*\u0000THINK_(\d+)\u0000\s*$/);
      if (thinkPH) {
        const body = t1.blocks[parseInt(thinkPH[1], 10)];
        const bodyHtml = render(body);
        out.push(`<details class="think-block"><summary>思考过程</summary><div class="think-body">${bodyHtml || '<span class="muted">(空)</span>'}</div></details>`);
        i++; continue;
      }
      const mathPH = ln.match(/^\s*\u0000MATH_(\d+)\u0000\s*$/);
      if (mathPH) {
        const m = mathBlocks[parseInt(mathPH[1], 10)];
        if (window.MarkdownKatex) {
          const inner = window.MarkdownKatex.renderInline(m.code);
          out.push(`<div class="math math-block">${inner}</div>`);
        } else {
          out.push(`<pre class="md-code"><code>${escape(m.code)}</code></pre>`);
        }
        i++; continue;
      }
      const mathInline = ln.match(/^\u0000MATH_(\d+)\u0000$/);
      if (mathInline) {
        const m = mathBlocks[parseInt(mathInline[1], 10)];
        if (window.MarkdownKatex) {
          const inner = window.MarkdownKatex.renderInline(m.code);
          out.push(`<span class="math math-inline">${inner}</span>`);
        }
        i++; continue;
      }

      // 水平线
      if (/^\s*---+\s*$/.test(ln)) { out.push('<hr>'); i++; continue; }

      // 标题
      const h = ln.match(/^(#{1,6})\s+(.+)$/);
      if (h) {
        const lvl = h[1].length;
        out.push(`<h${lvl}>${inlineMd(escape(h[2]))}</h${lvl}>`);
        i++; continue;
      }

      // 引用 (> ...)
      if (/^>\s?/.test(ln)) {
        const buf = [];
        while (i < lines.length && /^>\s?/.test(lines[i])) { buf.push(lines[i].replace(/^>\s?/, '')); i++; }
        const inner = render(buf.join('\n'));
        out.push(`<blockquote>${inner}</blockquote>`);
        continue;
      }

      // 列表(无序 - * +)
      if (/^\s*[-*+]\s+/.test(ln)) {
        const buf = [];
        while (i < lines.length && /^\s*[-*+]\s+/.test(lines[i])) {
          buf.push(lines[i].replace(/^\s*[-*+]\s+/, ''));
          i++;
        }
        out.push(renderTodoOrList(buf));
        continue;
      }
      // 列表(有序 1. 2.)
      if (/^\s*\d+\.\s+/.test(ln)) {
        const buf = [];
        while (i < lines.length && /^\s*\d+\.\s+/.test(lines[i])) {
          buf.push(lines[i].replace(/^\s*\d+\.\s+/, ''));
          i++;
        }
        out.push('<ol>' + buf.map((x) => `<li>${inlineMd(escape(x))}</li>`).join('') + '</ol>');
        continue;
      }

      // 表格
      if (i + 1 < lines.length && /^\s*\|/.test(ln) && /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?\s*$/.test(lines[i + 1])) {
        const headerLine = ln.trim();
        const sepLine = lines[i + 1].trim();
        i += 2;
        const bodyLines = [];
        while (i < lines.length && /^\s*\|/.test(lines[i]) && lines[i].trim()) {
          bodyLines.push(lines[i].trim());
          i++;
        }
        out.push(renderTable(headerLine, sepLine, bodyLines));
        continue;
      }

      // 段落(连续非空行)
      if (ln.trim() === '') { i++; continue; }
      const paraBuf = [];
      while (i < lines.length && lines[i].trim() !== '' &&
             !/^#{1,6}\s/.test(lines[i]) && !/^>\s?/.test(lines[i]) &&
             !/^\s*[-*+]\s+/.test(lines[i]) && !/^\s*\d+\.\s+/.test(lines[i]) &&
             !/^\s*\u0000/.test(lines[i]) && !/^\s*---+\s*$/.test(lines[i])) {
        paraBuf.push(lines[i]);
        i++;
      }
      const text0 = paraBuf.join('\n');
      // 行内数学(如果上一步没有抽全,补一次)
      let paraHtml = inlineMd(escape(text0));
      // 把已抽出的行内 math 占位替换成真实 span
      paraHtml = paraHtml.replace(/\u0000MATH_(\d+)\u0000/g, (_, idx) => {
        const m = mathBlocks[parseInt(idx, 10)];
        if (!window.MarkdownKatex) return escape(m.code);
        return `<span class="math math-inline">${window.MarkdownKatex.renderInline(m.code)}</span>`;
      });
      out.push(`<p>${paraHtml.replace(/\n/g, '<br>')}</p>`);
    }
    return out.join('\n');
  }

  function renderTodoOrList(items) {
    // 区分任务列表(全部以 - [ ] / - [x] 开头)与普通列表
    const isTodo = items.every((x) => /^\[[ xX]\]\s+/.test(x));
    if (!isTodo) {
      return '<ul>' + items.map((x) => `<li>${inlineMd(escape(x))}</li>`).join('') + '</ul>';
    }
    return '<ul class="todo-list">' + items.map((x) => {
      const m = x.match(/^\[([ xX])\]\s+(.*)$/);
      const done = m[1].toLowerCase() === 'x';
      return `<li class="todo-item ${done ? 'todo-done' : ''}"><input type="checkbox" disabled ${done ? 'checked' : ''}><span class="todo-text">${inlineMd(escape(m[2]))}</span></li>`;
    }).join('') + '</ul>';
  }

  function escAttr(s) { return String(s).replace(/[^a-zA-Z0-9_-]/g, ''); }

  return { render };
})();
