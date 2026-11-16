// Worker do instalador do WhatsBot Pro: serve o script e cadastra deploy keys (somente leitura) no GitHub.
// Segredos (wrangler secret): GH_APP_ID, GH_APP_KEY (PEM PKCS#8), ADMIN_TOKEN. Var: CONTATO_URL (opcional).
import SCRIPT from "./whatsbot-pro.sh";

const OWNER = "Techify-one";
const REPO = "whatsbot-pro";
const UA = "techify-whatsbot-pro-instalador";

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" } });
const erro = (msg, status) => json({ ok: false, erro: msg }, status);

const b64url = (buf) =>
  btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

// JWT RS256 do GitHub App (vale 9 min) -> token de instalação restrito a este repositório.
async function tokenDoApp(env) {
  const pem = env.GH_APP_KEY.replace(/-----[^-]+-----|\s/g, "");
  const key = await crypto.subtle.importKey("pkcs8", Uint8Array.from(atob(pem), (c) => c.charCodeAt(0)),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const agora = Math.floor(Date.now() / 1000);
  const enc = (o) => b64url(new TextEncoder().encode(JSON.stringify(o)));
  const corpo = `${enc({ alg: "RS256", typ: "JWT" })}.${enc({ iat: agora - 30, exp: agora + 540, iss: String(env.GH_APP_ID) })}`;
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(corpo));
  const jwt = `${corpo}.${b64url(sig)}`;

  const inst = await gh(jwt, `/repos/${OWNER}/${REPO}/installation`);
  if (!inst.ok) throw new Error(`instalação do App não encontrada (${inst.status})`);
  const t = await gh(jwt, `/app/installations/${(await inst.json()).id}/access_tokens`, "POST",
    { repositories: [REPO], permissions: { administration: "write" } });
  if (!t.ok) throw new Error(`token de instalação recusado (${t.status})`);
  return (await t.json()).token;
}

const gh = (token, path, method = "GET", body) =>
  fetch(`https://api.github.com${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, accept: "application/vnd.github+json", "user-agent": UA,
      "x-github-api-version": "2022-11-28", ...(body ? { "content-type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });

// Só ed25519: curta, e é a que o script gera.
async function fingerprint(pub) {
  const m = /^ssh-ed25519 ([A-Za-z0-9+/]{43,}={0,2})( [^\r\n]{0,100})?$/.exec(pub.trim());
  if (!m) return null;
  try {
    const hash = await crypto.subtle.digest("SHA-256", Uint8Array.from(atob(m[1]), (c) => c.charCodeAt(0)));
    return "SHA256:" + btoa(String.fromCharCode(...new Uint8Array(hash))).replace(/=+$/, "");
  } catch {
    return null; // base64 inválido: é erro de entrada (400), não falha do servidor
  }
}

async function registrarChave(req, env) {
  const b = await req.json().catch(() => null);
  const email = String(b?.email ?? "").trim().toLowerCase();
  const pub = String(b?.chave_publica ?? "").trim();
  const host = String(b?.maquina ?? "").replace(/[^\w.-]/g, "").slice(0, 40);
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return erro("e-mail inválido.", 400);
  const fp = await fingerprint(pub);
  if (!fp) return erro("chave pública inválida (use ssh-ed25519).", 400);

  const aluno = await env.DB.prepare("SELECT max_chaves FROM alunos WHERE email = ? AND ativo = 1").bind(email).first();
  if (!aluno) return erro("e-mail não liberado. Fale com a Techify.", 403);

  const base = { ok: true, repositorio: `git@github.com:${OWNER}/${REPO}.git`, contato: env.CONTATO_URL || "" };
  const ja = await env.DB.prepare("SELECT 1 FROM chaves WHERE email = ? AND fingerprint = ? AND revogada_em IS NULL").bind(email, fp).first();
  if (ja) return json({ ...base, reutilizada: true });

  const { n } = await env.DB.prepare("SELECT COUNT(*) AS n FROM chaves WHERE email = ? AND revogada_em IS NULL").bind(email).first();
  if (n >= aluno.max_chaves) return erro(`limite de ${aluno.max_chaves} chave(s) ativa(s) atingido. Reutilize a chave já gerada ou fale com a Techify.`, 429);

  const titulo = `${email} ${host} ${new Date().toISOString().slice(0, 10)}`.slice(0, 100);
  const token = await tokenDoApp(env);
  const r = await gh(token, `/repos/${OWNER}/${REPO}/keys`, "POST", { title: titulo, key: pub, read_only: true });
  if (r.status === 422) return erro("o GitHub recusou esta chave (já em uso em outro lugar). Gere outra.", 409);
  if (!r.ok) return erro(`falha no GitHub (${r.status}).`, 502);
  // A chave já existe no GitHub. Se não der para registrá-la na base, desfaz lá: uma chave que o D1 não
  // conhece nunca seria contada no limite nem revogada.
  let id;
  try {
    ({ id } = await r.json());
    await env.DB.prepare("INSERT INTO chaves (email, github_id, fingerprint, titulo, ip) VALUES (?, ?, ?, ?, ?)")
      .bind(email, id, fp, titulo, req.headers.get("cf-connecting-ip")).run();
  } catch (e) {
    if (id) await gh(token, `/repos/${OWNER}/${REPO}/keys/${id}`, "DELETE").catch(() => {});
    throw e;
  }
  return json({ ...base, restantes: aluno.max_chaves - n - 1 });
}

// POST /pro/admin/revogar {email} ou {id}: remove do GitHub e marca na base.
async function revogar(req, env) {
  const auth = req.headers.get("authorization") ?? "";
  if (!env.ADMIN_TOKEN || auth !== `Bearer ${env.ADMIN_TOKEN}`) return erro("não autorizado.", 401);
  const b = await req.json().catch(() => ({}));
  const { results } = b.id
    ? await env.DB.prepare("SELECT id, github_id FROM chaves WHERE id = ? AND revogada_em IS NULL").bind(b.id).all()
    : await env.DB.prepare("SELECT id, github_id FROM chaves WHERE email = ? AND revogada_em IS NULL").bind(String(b.email ?? "").toLowerCase()).all();
  if (!results.length) return erro("nenhuma chave ativa encontrada.", 404);
  const token = await tokenDoApp(env);
  let removidas = 0;
  for (const c of results) {
    const r = await gh(token, `/repos/${OWNER}/${REPO}/keys/${c.github_id}`, "DELETE");
    if (r.status === 204 || r.status === 404) {
      await env.DB.prepare("UPDATE chaves SET revogada_em = datetime('now') WHERE id = ?").bind(c.id).run();
      removidas++;
    }
  }
  return json({ ok: true, removidas, total: results.length });
}

export default {
  async fetch(req, env) {
    const { pathname } = new URL(req.url);
    try {
      if (req.method === "GET" && pathname === "/whatsbot-pro")
        return new Response(SCRIPT, { headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
      if (req.method === "POST" && pathname === "/pro/chave") return await registrarChave(req, env);
      if (req.method === "POST" && pathname === "/pro/admin/revogar") return await revogar(req, env);
      return erro("não encontrado.", 404);
    } catch (e) {
      console.error(e.message);
      return erro("erro interno.", 500);
    }
  },
};
