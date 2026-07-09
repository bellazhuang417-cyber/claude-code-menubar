// Claude Code Menubar — front-end renderer.
// Hosted inside hs.webview; no frameworks, no build step.
//
// Public entry points (called by Lua via evaluateJavaScript):
//   window.renderSessions({ sessions, top, now })  — full list refresh
//   window.renderLog({ sid, lines })               — expanded-row log fill
//
// User actions go back to Lua via `hammerspoon://action?key=value` URLs
// intercepted by webview.lua's navigationCallback.

// ---------- MOCK MODE ----------
// Set to true when opening this index.html directly in Safari/Chrome to
// preview the visuals without Hammerspoon. The mock data exercises all
// four states + permission card + Chinese labels.
// To preview visuals in a browser without Hammerspoon, flip this to `true`
// and open index.html directly (or via a static server). Ship value: false.
const MOCK_MODE = false;

// Seconds the PermissionRequest hook waits for a remote decision — keep in
// sync with DECISION_WAIT in hooks/update_status.py.
const REMOTE_WINDOW = 120;

const MOCK_SESSIONS = [
  {
    session_id: "aaa-pending-with-perm",
    effective_state: "pending",
    project: "workspace",
    label: "帮我加一个菜单栏通知功能",
    updated_at: Math.floor(Date.now() / 1000) - 30 * 60,
    cwd: "/Users/you/Projects/workspace",
    transcript_path: "",
    pending_permission: {
      tool: "bash",
      command: "rm -rf node_modules && npm install",
      reason: "Claude wants to reinstall dependencies after package.json change",
    },
  },
  {
    session_id: "bbb-pending-no-perm",
    effective_state: "pending",
    project: "schema-review",
    label: "Review the proposed SKU schema",
    updated_at: Math.floor(Date.now() / 1000) - 120,
    cwd: "/Users/you/Projects/schema-review",
    transcript_path: "",
    pending_permission: null,
  },
  {
    session_id: "ccc-running",
    effective_state: "running",
    project: "claude-code-menubar",
    label: "Implementing v0.2 webview pipeline",
    updated_at: Math.floor(Date.now() / 1000) - 5,
    cwd: "/Users/you/Projects/claude-code-menubar",
    transcript_path: "",
    pending_permission: null,
  },
  {
    session_id: "ddd-done",
    effective_state: "done",
    project: "ops-toolkit",
    label: "Published v1.2 to GitHub",
    updated_at: Math.floor(Date.now() / 1000) - 12,
    cwd: "/Users/you/Projects/ops-toolkit",
    transcript_path: "",
    pending_permission: null,
  },
];

// ---------- State ----------
const state = {
  sessions: [],
  expandedSid: null,
  logs: {}, // sid -> [{ kind, text }]
  serverNow: Math.floor(Date.now() / 1000),
  clientNowAtPush: Math.floor(Date.now() / 1000),
};

// ---------- Utilities ----------
function nowSeconds() {
  // Estimate "current time" using the offset between server now (epoch from
  // Lua) and our wall clock at the time of last push, then advance by the
  // wall-clock delta. This way age strings keep ticking between pushes.
  const wallNow = Math.floor(Date.now() / 1000);
  return state.serverNow + (wallNow - state.clientNowAtPush);
}

function formatAge(updatedAt) {
  const age = Math.max(0, nowSeconds() - (updatedAt || 0));
  if (age < 5) return "now";
  if (age < 60) return age + "s";
  if (age < 3600) return Math.floor(age / 60) + "m";
  if (age < 86400) return Math.floor(age / 3600) + "h";
  return Math.floor(age / 86400) + "d";
}

function shortCwd(cwd) {
  if (!cwd) return "";
  const parts = cwd.split("/").filter(Boolean);
  if (parts.length <= 2) return cwd;
  return ".../" + parts.slice(-2).join("/");
}

function escapeHtml(s) {
  if (s == null) return "";
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function statusLabel(s) {
  if (s === "running") return "working";
  if (s === "pending") return "needs input";
  if (s === "done") return "done";
  return s || "";
}

function callLua(action, params) {
  if (MOCK_MODE) {
    console.log("[mock] action:", action, params);
    return;
  }
  // Primary: WKWebView message handler (reliable). The old hammerspoon://
  // navigation trick is kept as fallback only — modern WebKit drops
  // JS-initiated custom-scheme navigations silently.
  if (
    window.webkit &&
    window.webkit.messageHandlers &&
    window.webkit.messageHandlers.claudeMenubar
  ) {
    window.webkit.messageHandlers.claudeMenubar.postMessage({
      action: action,
      params: params || {},
    });
    return;
  }
  let url = "hammerspoon://" + action;
  if (params) {
    const qs = Object.keys(params)
      .map((k) => encodeURIComponent(k) + "=" + encodeURIComponent(params[k]))
      .join("&");
    if (qs) url += "?" + qs;
  }
  // Navigation is intercepted by webview.lua — no actual page load happens.
  window.location.href = url;
}

// ---------- Render ----------
function tacSrcFor(status) {
  // Legacy: returns a URL string (for MOCK_MODE / fallback <img> path).
  // For production we use tacInlineFor() which returns raw SVG XML.
  if (status === "running") return "assets/tac-working.svg";
  if (status === "pending") return "assets/tac-needs-input.svg";
  if (status === "done") return "assets/tac-complete.svg";
  return "assets/tac.svg";
}

// Return SVG markup for inline rendering. SMIL animations (tail sway, eye
// blink) only fire when the SVG is in the live DOM — not when loaded via <img>.
// We rewrite duplicate IDs per row to avoid <defs> collisions when several
// Tacs appear on the same page.
function tacInlineFor(status, uniqueSuffix) {
  if (typeof window === "undefined" || !window.TAC_SVGS) {
    // MOCK_MODE / browser preview: fall back to <img>
    return '<img src="' + tacSrcFor(status) + '" alt="Tac ' + escapeHtml(status || "idle") + '" />';
  }
  const key = (status === "running" || status === "pending" || status === "done") ? status : "idle";
  let svg = window.TAC_SVGS[key] || window.TAC_SVGS.idle || "";
  if (!svg) return "";
  // Per-row ID rewrite to keep multiple Tacs in the DOM from clobbering each other's gradients/symbols.
  const ids = ["g-helmet","g-visor","g-cheek","g-body","eye-working","eye-input","eye-done","eye-idle","tac","tac-working"];
  for (const id of ids) {
    const safeId = id + "-" + uniqueSuffix;
    // id="X" -> id="X-suffix"
    svg = svg.replace(new RegExp('id="' + id + '"', 'g'), 'id="' + safeId + '"');
    // url(#X) -> url(#X-suffix)
    svg = svg.replace(new RegExp('url\\(#' + id + '\\)', 'g'), 'url(#' + safeId + ')');
    // href="#X" -> href="#X-suffix"
    svg = svg.replace(new RegExp('href="#' + id + '"', 'g'), 'href="#' + safeId + '"');
  }
  return svg;
}

function buildSessionRow(sess) {
  const status = sess.effective_state;
  const isExpanded = state.expandedSid === sess.session_id;
  // Use last 8 chars of session_id as a unique-enough suffix for SVG id rewrites
  const sidSuffix = (sess.session_id || "row").replace(/[^a-zA-Z0-9]/g, "").slice(-8);
  const tacMarkup = tacInlineFor(status, sidSuffix);

  let metaInner = "";
  if (status === "running") {
    metaInner =
      '<span class="stx">working <span class="dots-3"><i></i><i></i><i></i></span></span>';
  } else if (status === "pending") {
    // Two flavors of "pending":
    //   - with pending_permission: Claude is waiting for Allow/Deny on a tool call
    //   - without: Claude finished its turn, waiting for the user to reply
    if (sess.pending_permission) {
      metaInner = '<span class="stx">needs permission</span>';
    } else {
      metaInner = '<span class="stx">needs reply</span>';
    }
  } else if (status === "done") {
    // Claude finished its turn recently (Stop hook). Distinct from idle so a
    // just-completed answer is visible at a glance; fades to idle after 30 min.
    metaInner = '<span class="stx">done ✓</span>';
  } else if (status === "idle") {
    metaInner = '<span class="stx idle">idle</span>';
  }
  if (sess.cwd) {
    metaInner +=
      '<span class="dot">·</span><span class="cwd">' +
      escapeHtml(shortCwd(sess.cwd)) +
      "</span>";
  }

  // data-flavor distinguishes two pending variants for CSS targeting:
  //   permission = waiting on Allow/Deny (loud halo)
  //   reply      = waiting on user to type a message back (calm)
  const flavor = (status === "pending" && sess.pending_permission) ? "permission" : "reply";
  const html = `
    <div class="sess ${isExpanded ? "expanded" : ""}" data-status="${escapeHtml(
    status
  )}" data-flavor="${flavor}" data-sid="${escapeHtml(sess.session_id)}">
      <div class="av">${tacMarkup}</div>
      <div class="mid">
        <div class="nm">
          <span class="lbl">${escapeHtml(sess.title || sess.label || "(no recent message)")}</span>
        </div>
        <div class="meta">
          <span class="proj-sub">${escapeHtml(sess.project || "session")}</span>
          ${sess.label && sess.title && sess.label !== sess.title
            ? '<span class="dot">·</span><span class="latest-msg">' + escapeHtml(sess.label) + '</span>'
            : ''}
          <span class="dot">·</span>
          ${metaInner}
        </div>
      </div>
      <div class="right">
        <span class="age" data-age-for="${escapeHtml(
          sess.session_id
        )}">${formatAge(sess.updated_at)}</span>
        <span class="caret">›</span>
      </div>
    </div>
  `;
  return html;
}

function buildDetail(sess) {
  const sid = sess.session_id;
  const lines = state.logs[sid] || null;

  let logHtml = "";
  if (lines && lines.length > 0) {
    logHtml = lines
      .map((ln) => {
        let pfx = "·";
        let cls = "assistant";
        if (ln.kind === "user") {
          pfx = "›";
          cls = "user";
        } else if (ln.kind === "tool") {
          pfx = "⏵";
          cls = "tool";
        }
        return `<span class="ln ${cls}"><span class="pfx">${pfx}</span>${escapeHtml(
          ln.text || ""
        )}</span>`;
      })
      .join("");
  } else if (lines && lines.length === 0) {
    logHtml = '<span class="empty-log">No transcript content yet.</span>';
  } else {
    logHtml = '<span class="empty-log">Loading log…</span>';
  }

  let actionHtml = "";
  const status = sess.effective_state;
  if (status === "pending") {
    if (sess.pending_permission) {
      const p = sess.pending_permission;
      // Remote Allow/Deny only works while the PermissionRequest hook is
      // still blocked waiting for our decision file (REMOTE_WINDOW seconds
      // from requested_at). After that the buttons would be dead — replace
      // them with an honest "handle it in the window" hint.
      const reqAge = nowSeconds() - (p.requested_at || sess.updated_at || 0);
      const remoteAlive = p.requested_at && reqAge < REMOTE_WINDOW;
      const buttonsHtml = remoteAlive
        ? `<div class="pbtns">
            <button class="pbtn allow" data-decide="allow" data-decide-sid="${escapeHtml(
              sid
            )}">✓ Allow</button>
            <button class="pbtn deny" data-decide="deny" data-decide-sid="${escapeHtml(
              sid
            )}">✗ Deny</button>
          </div>
          <div class="premote">remote window ${Math.max(
            0,
            Math.round(REMOTE_WINDOW - reqAge)
          )}s</div>`
        : `<div class="pexpired">远程确认已超时 — 请到 Claude Code 窗口处理</div>`;
      actionHtml = `
        <div class="action permission">
          <div class="ptitle">PERMISSION REQUESTED · ${escapeHtml(
            p.tool || "tool"
          )}</div>
          ${
            p.reason
              ? `<div class="preason">${escapeHtml(p.reason)}</div>`
              : ""
          }
          <div class="pcmd"><span class="ps">$</span>${escapeHtml(
            p.command || ""
          )}</div>
          ${buttonsHtml}
        </div>
      `;
    } else {
      actionHtml = `
        <div class="action waiting">
          <b>Waiting for your response</b> — switch to your Claude Code window.
        </div>
      `;
    }
  } else if (status === "running") {
    // Try to find the last tool in the log.
    let lastTool = null;
    if (lines) {
      for (let i = lines.length - 1; i >= 0; i--) {
        if (lines[i].kind === "tool") {
          lastTool = lines[i].text;
          break;
        }
      }
    }
    actionHtml = `
      <div class="action working">
        <div class="spinner"></div>
        <div class="wtitle">
          ${lastTool ? "Running " + escapeHtml(lastTool) : "Claude is working…"}
          <span class="wsub">updated ${formatAge(sess.updated_at)} ago</span>
        </div>
      </div>
    `;
  } else if (status === "done") {
    actionHtml = `
      <div class="action complete">
        <div class="ctitle">Completed</div>
        ${formatAge(sess.updated_at)} ago
      </div>
    `;
  }

  return `
    <div class="sess-detail" data-detail-for="${escapeHtml(sid)}">
      <div class="log">${logHtml}</div>
      ${actionHtml}
    </div>
  `;
}

function render() {
  const list = state.sessions;
  const counts = { running: 0, pending: 0, done: 0 };
  list.forEach((s) => {
    if (counts[s.effective_state] != null) counts[s.effective_state]++;
  });

  document.getElementById("cnt-run").textContent = counts.running;
  document.getElementById("cnt-wait").textContent = counts.pending;
  document.getElementById("cnt-done").textContent = counts.done;
  document.getElementById("head-count").textContent =
    "· " + list.length + (list.length === 1 ? " session" : " sessions");

  const container = document.getElementById("sess-list");
  if (list.length === 0) {
    container.innerHTML = '<div class="empty">No active sessions.</div>';
    return;
  }

  let html = "";
  list.forEach((sess) => {
    html += buildSessionRow(sess);
    if (state.expandedSid === sess.session_id) {
      html += buildDetail(sess);
    }
  });
  container.innerHTML = html;
}

// ---------- Public API (Lua → JS) ----------
// Measure the rendered panel's real height and ask Lua to shrink the
// webview window to match — kills the empty/transparent area below.
function reportHeight() {
  if (MOCK_MODE) return;
  // Schedule after the browser has had a chance to lay out.
  requestAnimationFrame(function () {
    const dd = document.querySelector(".dropdown");
    if (!dd) return;
    const h = Math.ceil(dd.getBoundingClientRect().height) + 4;  // small margin for shadow
    callLua("resize", { height: h });
  });
}

window.renderSessions = function (data) {
  state.sessions = (data && data.sessions) || [];
  state.serverNow = (data && data.now) || Math.floor(Date.now() / 1000);
  state.clientNowAtPush = Math.floor(Date.now() / 1000);

  // If the expanded session went away, collapse.
  if (state.expandedSid) {
    const stillThere = state.sessions.some(
      (s) => s.session_id === state.expandedSid
    );
    if (!stillThere) {
      state.expandedSid = null;
    }
  }
  render();
  reportHeight();
};

window.renderSkins = function (data) {
  const skins = (data && data.skins) || [];
  const tabs = document.getElementById("sp-tabs");
  if (!tabs) return;
  tabs.innerHTML = skins
    .map(
      (s) =>
        `<button class="sp-tab ${
          s.active ? "active" : ""
        }" data-skin="${escapeHtml(s.name)}">${escapeHtml(
          s.displayName || s.name
        )}</button>`
    )
    .join("");
  reportHeight();
};

// v0.4: render pet body + bubble. Called by Lua M.pushPet.
//   data = { skinName, skinData, mood, text, subtext }
window.renderPet = function (data) {
  if (!data) return;
  const petBody = document.getElementById("pet-body");
  const bubble = document.getElementById("bubble");
  const bubbleText = document.getElementById("bubble-text");
  const bubbleSub = document.getElementById("bubble-sub");
  if (!petBody || !bubble) return;

  // Bubble text/state
  const mood = data.mood || "idle";
  const hasBubble = !!(data.text && mood !== "idle");
  if (hasBubble) {
    bubbleText.textContent = data.text;
    bubbleSub.textContent = data.subtext || "";
    bubbleSub.style.display = data.subtext ? "" : "none";
    bubble.setAttribute("data-mood", mood);
    bubble.hidden = false;
  } else {
    bubble.hidden = true;
  }

  // Pet body rendering — only rebuild markup if skin OR mood changed
  const sig = (data.skinName || "tac") + ":" + mood;
  if (petBody.getAttribute("data-sig") === sig) return;
  petBody.setAttribute("data-sig", sig);

  const s = data.skinData || {};
  petBody.innerHTML = "";
  if (s.kind === "gif") {
    const url = (s.urls && (s.urls[mood] || s.urls.input || s.urls.idle)) || "";
    if (url) {
      const img = document.createElement("img");
      img.className = "sprite";
      img.style.width = s.w + "px";
      img.style.height = s.h + "px";
      img.src = url;
      petBody.appendChild(img);
    }
  } else if (s.kind === "sprite") {
    const anim = (s.sprites && (s.sprites[mood] || s.sprites.input)) || null;
    if (anim) {
      const div = document.createElement("div");
      div.className = "sprite";
      div.style.width = s.w + "px";
      div.style.height = s.h + "px";
      div.style.background = "url('" + anim.url + "') no-repeat";
      div.style.backgroundSize = anim.sheetW + "px " + anim.sheetH + "px";
      div.style.backgroundPosition = anim.startX + "px " + anim.startY + "px";
      div.style.animation =
        "sprite-loop-" + mood + " " + anim.duration + "s steps(" + anim.count + ") infinite";
      // Inject the @keyframes for this mood
      const styleId = "sprite-kf-" + mood;
      let styleEl = document.getElementById(styleId);
      if (!styleEl) {
        styleEl = document.createElement("style");
        styleEl.id = styleId;
        document.head.appendChild(styleEl);
      }
      styleEl.textContent =
        "@keyframes sprite-loop-" + mood + " { from { background-position: " +
        anim.startX + "px " + anim.startY + "px; } to { background-position: " +
        anim.endX + "px " + anim.startY + "px; } }";
      petBody.appendChild(div);
    }
  } else {
    // Tac SVG fallback
    const svgs = s.svgs || {};
    const svg = svgs[mood] || svgs.idle || svgs.input || "";
    const wrap = document.createElement("div");
    wrap.className = "tac";
    wrap.innerHTML = svg;
    petBody.appendChild(wrap);
  }
};

window.renderLog = function (data) {
  if (!data || !data.sid) return;
  state.logs[data.sid] = data.lines || [];
  render();
};

// ---------- Event delegation ----------
document.addEventListener("click", function (e) {
  // v0.4: bubble close (× on the pet's bubble)
  const bClose = e.target.closest("#bubble-close");
  if (bClose) {
    const bubble = document.getElementById("bubble");
    if (bubble) bubble.hidden = true;
    callLua("bubble-dismiss", {});
    e.preventDefault();
    e.stopPropagation();
    return;
  }
  // v0.4: click on pet body → toggle expand/collapse
  const petBody = e.target.closest("#pet-body");
  if (petBody) {
    callLua("toggle-expand", {});
    e.preventDefault();
    e.stopPropagation();
    return;
  }
  // Panel close button in the header
  if (e.target.closest(".panel-close")) {
    callLua("toggle-expand", {});
    e.preventDefault();
    e.stopPropagation();
    return;
  }
  // Skin picker tabs
  const sbtn = e.target.closest("[data-skin]");
  if (sbtn) {
    const name = sbtn.getAttribute("data-skin");
    // Optimistic: mark active immediately
    document
      .querySelectorAll(".sp-tab")
      .forEach((b) => b.classList.toggle("active", b === sbtn));
    callLua("set-skin", { name: name });
    e.preventDefault();
    e.stopPropagation();
    return;
  }
  // Permission card Allow / Deny → Lua writes the decision file, the blocked
  // PermissionRequest hook picks it up and answers Claude Code directly.
  const dbtn = e.target.closest("[data-decide]");
  if (dbtn) {
    const sid = dbtn.getAttribute("data-decide-sid");
    const behavior = dbtn.getAttribute("data-decide");
    callLua("decide", { sid: sid, behavior: behavior });
    // Optimistic UI: clear the card immediately; Lua re-pushes real state.
    const sess = state.sessions.find((s) => s.session_id === sid);
    if (sess) {
      sess.pending_permission = null;
      sess.effective_state = "running";
      render();
    }
    e.preventDefault();
    e.stopPropagation();
    return;
  }
  // Footer buttons
  const fbtn = e.target.closest("[data-action]");
  if (fbtn) {
    const action = fbtn.getAttribute("data-action");
    callLua(action, {});
    e.preventDefault();
    return;
  }
  // Session row toggle
  const row = e.target.closest(".sess");
  if (row) {
    const sid = row.getAttribute("data-sid");
    if (state.expandedSid === sid) {
      state.expandedSid = null;
    } else {
      state.expandedSid = sid;
      // Ask Lua to fetch fresh log lines for this session.
      if (!state.logs[sid]) {
        state.logs[sid] = null; // marker: loading
      }
      callLua("expand", { sid: sid });
    }
    render();
    return;
  }
});

// ---------- Keyboard shortcuts ----------
document.addEventListener("keydown", function (e) {
  // Esc → collapse the panel back to just-the-pet.
  if (e.key === "Escape" && document.body.classList.contains("mode-expanded")) {
    callLua("toggle-expand", {});
    e.preventDefault();
  }
});

// ---------- Age tick ----------
setInterval(function () {
  document.querySelectorAll("[data-age-for]").forEach(function (el) {
    const sid = el.getAttribute("data-age-for");
    const sess = state.sessions.find((s) => s.session_id === sid);
    if (sess) el.textContent = formatAge(sess.updated_at);
  });
}, 5000);

// ---------- Boot ----------
if (MOCK_MODE) {
  window.renderSessions({
    sessions: MOCK_SESSIONS,
    top: "pending",
    now: Math.floor(Date.now() / 1000),
  });
} else {
  // First render of empty state until Lua pushes data.
  render();
}
