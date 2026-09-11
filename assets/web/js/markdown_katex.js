// 轻量 KaTeX 兼容 math 渲染(无外部依赖)
// 支持:
//   定界符: $...$  (inline),  $$...$$  (block)
//   字符: 希腊字母(alpha..omega / Alpha..Omega)、关系符(<=, >=, !=, ~=, ≡, ≈, ∈, ∉, ⊂, ⊃, ⊆, ⊇, ∪, ∩, ∅, ∞)、
//         运算(+, -, *, /, ×, ÷, ·, ±)、箭头(->, =>, <-, <=, <->, =>, <-->)。
//   结构: 上标 a^b / a^{...}、下标 a_b / a_{...}、分数 \frac{a}{b}、根式 \sqrt{x} / \sqrt[n]{x}、
//         求和 \sum_{i=1}^{n}、积分 \int_{a}^{b}、极限 \lim_{x→0}、向量 \vec{x} / \hat{x} / \bar{x}。
//   环境: pmatrix / bmatrix / cases / matrix (以 \begin{...}...\end{...} 包围)。
// 不支持: 复杂字体(mathbf 等用普通文本),颜色,标签.够常见 LLM 输出使用。
window.MarkdownKatex = (function () {
  // 希腊字母
  const GREEK = {
    alpha: 'α', beta: 'β', gamma: 'γ', delta: 'δ', epsilon: 'ε', zeta: 'ζ',
    eta: 'η', theta: 'θ', iota: 'ι', kappa: 'κ', lambda: 'λ', mu: 'μ',
    nu: 'ν', xi: 'ξ', pi: 'π', rho: 'ρ', sigma: 'σ', tau: 'τ',
    upsilon: 'υ', phi: 'φ', varphi: 'φ', chi: 'χ', psi: 'ψ', omega: 'ω',
    varepsilon: 'ε', vartheta: 'ϑ', varsigma: 'ς', varrho: 'ϱ',
    Alpha: 'Α', Beta: 'Β', Gamma: 'Γ', Delta: 'Δ', Epsilon: 'Ε', Zeta: 'Ζ',
    Eta: 'Η', Theta: 'Θ', Iota: 'Ι', Kappa: 'Κ', Lambda: 'Λ', Mu: 'Μ',
    Nu: 'Ν', Xi: 'Ξ', Pi: 'Π', Rho: 'Ρ', Sigma: 'Σ', Tau: 'Τ',
    Upsilon: 'Υ', Phi: 'Φ', Chi: 'Χ', Psi: 'Ψ', Omega: 'Ω',
  };
  // 符号
  const SYMBOLS = {
    leq: '≤', le: '≤', geq: '≥', ge: '≥', neq: '≠', ne: '≠',
    approx: '≈', sim: '~', simeq: '≃', cong: '≅', equiv: '≡', propto: '∝',
    in: '∈', notin: '∉', ni: '∋', subset: '⊂', supset: '⊃',
    subseteq: '⊆', supseteq: '⊇', cup: '∪', cap: '∩', emptyset: '∅',
    forall: '∀', exists: '∃', nexists: '∄', therefore: '∴', because: '∵',
    to: '→', rightarrow: '→', Rightarrow: '⇒', leftarrow: '←', Leftarrow: '⇐',
    leftrightarrow: '↔', Leftrightarrow: '⇔', mapsto: '↦',
    times: '×', cdot: '·', div: '÷', pm: '±', mp: '∓', ast: '∗', star: '∗',
    partial: '∂', nabla: '∇', hbar: 'ℏ', ell: 'ℓ', Re: 'ℜ', Im: 'ℑ',
    aleph: 'ℵ', wp: '℘', prime: '′', dprime: '″', tri: '△', square: '□',
    circ: '∘', bullet: '•', setminus: '∖', bigcap: '⋂', bigcup: '⋃',
    inf: '∞', infty: '∞', hspace: ' ', '': ' ', quad: '  ', qquad: '    ', ',': ' ', ';': ' ', '!': '',
  };
  const FUNCS = {
    sum: '∑', prod: '∏', coprod: '∐', oint: '∮', bigotimes: '⨂', bigoplus: '⨁',
    int: '∫', iint: '∬', iiint: '∭', int_: '∫',
    lim: 'lim', limsup: 'lim sup', liminf: 'lim inf', inf: 'inf', sup: 'sup', max: 'max', min: 'min',
    sin: 'sin', cos: 'cos', tan: 'tan', cot: 'cot', sec: 'sec', csc: 'csc',
    arcsin: 'arcsin', arccos: 'arccos', arctan: 'arctan', sinh: 'sinh', cosh: 'cosh', tanh: 'tanh',
    log: 'log', ln: 'ln', exp: 'exp', det: 'det', gcd: 'gcd',
    vec: '→', hat: 'ˆ', bar: '¯', tilde: '˜', dot: '˙', ddot: '¨',
  };
  // 数字 unicode
  function escapeHTML(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
  // 渲染 token 流;token = {t:'sym'|'num'|'text'|'group'|'frac'|'sqrt'|'op'|'sub'|'sup'|'matrix'|'func'}
  // 简化:按顺序解析,遇到 {...} 当 group 递归
  function tokenize(src) {
    const out = [];
    let i = 0;
    while (i < src.length) {
      const c = src[i];
      if (c === ' ') { i++; continue; }
      if (c === '\\') {
        // 命令: \name 或 \name{...}
        let name = '';
        let j = i + 1;
        while (j < src.length && /[a-zA-Z]/.test(src[j])) { name += src[j]; j++; }
        if (name) {
          // 收集后续 {arg} (可能多个)
          const args = [];
          // 也支持可选的 [arg] 作为第一个参数(给 \sqrt[3]{x})
          if (j < src.length && src[j] === '[') {
            const end = matchBracket(src, j);
            args.push(src.slice(j + 1, end));
            j = end + 1;
          }
          while (j < src.length && src[j] === '{') {
            const end = matchBrace(src, j);
            args.push(src.slice(j + 1, end));
            j = end + 1;
          }
          // 单字符命令: \, \; \! \$
          if (name in SYMBOLS) {
            out.push({ t: 'sym', v: SYMBOLS[name] });
          } else if (name in GREEK) {
            out.push({ t: 'sym', v: GREEK[name] });
          } else if (name === 'frac') {
            if (args.length >= 2) out.push({ t: 'frac', a: args[0], b: args[1] });
          } else if (name === 'sqrt') {
            if (args.length === 1) out.push({ t: 'sqrt', a: args[0], b: null });
            else if (args.length >= 2) out.push({ t: 'sqrt', a: args[1], b: args[0] });
          } else if (name === 'begin') {
            // \begin{env}...\end{env}
            if (args.length >= 1) {
              const env = args[0];
              const endIdx = src.indexOf('\\end{' + env + '}', j);
              if (endIdx >= 0) {
                const body = src.slice(j, endIdx);
                // body 由 \\ 分行
                const rows = body.split(/\\\\/).map((r) => r.trim()).filter(Boolean);
                out.push({ t: 'matrix', env: env, rows: rows });
                j = endIdx + ('\\end{' + env + '}').length;
              }
            }
          } else if (name in FUNCS) {
            // \sum / \int 等接 _ / ^ 后吃 group
            const opSym = FUNCS[name];
            const opTok = { t: 'op', op: opSym, sub: null, sup: null };
            while (j < src.length && (src[j] === '_' || src[j] === '^')) {
              const op = src[j];
              const next = eatGroup(src, j + 1);
              if (op === '^') opTok.sup = next.val;
              else opTok.sub = next.val;
              j = next.next;
            }
            out.push(opTok);
          } else {
            out.push({ t: 'sym', v: name });
          }
          i = j;
          continue;
        }
        i++;
        continue;
      }
      if (c === '{') {
        const end = matchBrace(src, i);
        out.push({ t: 'group', v: src.slice(i + 1, end) });
        i = end + 1;
        continue;
      }
      if (c === '^' || c === '_') {
        const kind = c === '^' ? 'sup' : 'sub';
        const next = eatGroup(src, i + 1);
        // 把 sub/sup 粘到前一个 token 上
        if (out.length) {
          out[out.length - 1][kind] = next.val;
        } else {
          out.push({ t: kind, v: next.val });
        }
        i = next.next;
        continue;
      }
      if (/[0-9.]/.test(c)) {
        let j = i;
        while (j < src.length && /[0-9.]/.test(src[j])) j++;
        out.push({ t: 'num', v: src.slice(i, j) });
        i = j; continue;
      }
      if (/[a-zA-Z]/.test(c)) {
        // 连续字母当变量
        let j = i;
        while (j < src.length && /[a-zA-Z]/.test(src[j])) j++;
        out.push({ t: 'text', v: src.slice(i, j) });
        i = j; continue;
      }
      // 其它单字符符号
      const M = { '<=': '≤', '>=': '≥', '!=': '≠', '~=': '≅', '->': '→', '=>': '⇒', '<-': '←', '<->': '↔', '×': '×', '÷': '÷', '·': '·', '±': '±', '∞': '∞', '∈': '∈', '∉': '∉', '∪': '∪', '∩': '∩', '∅': '∅', '→': '→', '⇒': '⇒', '↔': '↔', '∑': '∑', '∏': '∏', '∫': '∫', '∂': '∂', '∇': '∇' };
      const two = src.slice(i, i + 2);
      if (two in M) { out.push({ t: 'sym', v: M[two] }); i += 2; continue; }
      if (M[c]) { out.push({ t: 'sym', v: M[c] }); i++; continue; }
      out.push({ t: 'text', v: c });
      i++;
    }
    return out;
  }
  function matchBrace(s, i) {
    let depth = 0;
    for (let k = i; k < s.length; k++) {
      if (s[k] === '{') depth++;
      else if (s[k] === '}') { depth--; if (depth === 0) return k; }
    }
    return s.length - 1;
  }
  function matchBracket(s, i) {
    for (let k = i + 1; k < s.length; k++) {
      if (s[k] === ']') return k;
    }
    return s.length - 1;
  }
  function eatGroup(s, i) {
    while (i < s.length && s[i] === ' ') i++;
    if (i < s.length && s[i] === '{') {
      const end = matchBrace(s, i);
      return { val: s.slice(i + 1, end), next: end + 1 };
    }
    if (i < s.length && s[i] === '\\') {
      let j = i + 1;
      while (j < s.length && /[a-zA-Z]/.test(s[j])) j++;
      return { val: s.slice(i, j), next: j };
    }
    if (i < s.length) return { val: s[i], next: i + 1 };
    return { val: '', next: i };
  }
  // 渲染 token 数组为 HTML
  function renderTokens(tokens) {
    // 后处理:把 sup/sub 粘到前一个 token 上(同时清掉内部 _closed 标记)
    const flat = [];
    for (const t of tokens) {
      if (t.t === 'sup' || t.t === 'sub') {
        if (flat.length) flat[flat.length - 1][t.t] = t.v;
        else flat.push(t);
      } else {
        const cp = { ...t };
        delete cp._closed;
        flat.push(cp);
      }
    }
    const html = flat.map(tokenToHTML).filter(Boolean).join('');
    return html || '';
  }
  function tokenToHTML(t) {
    let sub = '', sup = '';
    if (t.t === 'sym' || t.t === 'num' || t.t === 'text') {
      if (t.sub) sub = `<span class="mx-sub">${renderInline(t.sub)}</span>`;
      if (t.sup) sup = `<span class="mx-sup">${renderInline(t.sup)}</span>`;
    }
    switch (t.t) {
      case 'sym': return `<span class="mx-sym">${escapeHTML(t.v)}</span>${sub}${sup}`;
      case 'num': return `<span class="mx-num">${escapeHTML(t.v)}</span>${sub}${sup}`;
      case 'text': return `<span class="mx-text">${escapeHTML(t.v)}</span>${sub}${sup}`;
      case 'group': return `<span class="mx-grp">${renderInline(t.v)}</span>`;
      case 'frac': return `<span class="mx-frac"><span class="mx-num">${renderInline(t.a)}</span><span class="mx-bar"></span><span class="mx-den">${renderInline(t.b)}</span></span>`;
      case 'sqrt': {
        const inner = renderInline(t.a);
        if (t.b) return `<span class="mx-sqrt"><span class="mx-rad"><span class="mx-sym">√</span><span class="mx-sup">${renderInline(t.b)}</span></span>${inner}</span>`;
        return `<span class="mx-sqrt"><span class="mx-rad"><span class="mx-sym">√</span></span>${inner}</span>`;
      }
      case 'op': {
        const opSub = t.sub ? `<span class="mx-sub">${renderInline(t.sub)}</span>` : '';
        const opSup = t.sup ? `<span class="mx-sup">${renderInline(t.sup)}</span>` : '';
        return `<span class="mx-op"><span class="mx-sym">${escapeHTML(t.op)}</span>${opSub}${opSup}</span>`;
      }
      case 'matrix': {
        const rows = t.rows.map((row) => {
          const cells = row.split('&').map((c) => `<span class="mx-cell">${renderInline(c.trim())}</span>`);
          return `<span class="mx-row">${cells.join('')}</span>`;
        });
        const paren = t.env === 'pmatrix' ? ['(', ')'] : t.env === 'bmatrix' ? ['[', ']'] : t.env === 'cases' ? ['{', ''] : ['', ''];
        return `<span class="mx-matrix"><span class="mx-lpar">${paren[0]}</span>${rows.join('')}<span class="mx-rpar">${paren[1]}</span></span>`;
      }
    }
    return '';
  }
  function renderInline(src) {
    return renderTokens(tokenize(src));
  }

  // 入口: 在已 escape 过的 HTML 字符串里,抠出 $...$ / $$...$$ 转 span,
  // 返回新的 HTML。注意:这要求调用方传入的是原始纯文本(未 escape)。
  // 因为我们要从原文中识别 $ 分隔符,再把 $...$ 之间的内容渲染后嵌入。
  // 返回值: HTML 字符串(已 escape 容器 + 渲染后数学块)。
  function apply(text) {
    if (!text || text.indexOf('$') < 0) return null;
    // 行间 $$ ... $$ 优先
    let out = '';
    let i = 0;
    while (i < text.length) {
      const start = text.indexOf('$$', i);
      if (start < 0) break;
      const end = text.indexOf('$$', start + 2);
      if (end < 0) break;
      out += escapeHTML(text.slice(i, start)) + `<div class="math math-block">${renderInline(text.slice(start + 2, end))}</div>`;
      i = end + 2;
    }
    if (i < text.length) out += escapeHTML(text.slice(i));
    // 再处理行内 $...$
    out = out.replace(/\$([^$\n]+?)\$/g, function (_, src) {
      return `<span class="math math-inline">${renderInline(src)}</span>`;
    });
    return out;
  }

  return { apply, renderInline };
})();
