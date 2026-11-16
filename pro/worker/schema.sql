-- Alunos liberados. max_chaves = quantas deploy keys ativas cada um pode ter (limite por aluno).
CREATE TABLE IF NOT EXISTS alunos (
  email       TEXT PRIMARY KEY,           -- minúsculo
  nome        TEXT,
  max_chaves  INTEGER NOT NULL DEFAULT 3,
  ativo       INTEGER NOT NULL DEFAULT 1,
  criado_em   TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Uma linha por deploy key cadastrada no GitHub. revogada_em preenchido = já removida lá.
CREATE TABLE IF NOT EXISTS chaves (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  email        TEXT NOT NULL REFERENCES alunos(email),
  github_id    INTEGER NOT NULL,          -- id da deploy key no GitHub (para remover)
  fingerprint  TEXT NOT NULL,             -- SHA256 da chave pública
  titulo       TEXT NOT NULL,
  ip           TEXT,
  criada_em    TEXT NOT NULL DEFAULT (datetime('now')),
  revogada_em  TEXT
);
CREATE INDEX IF NOT EXISTS idx_chaves_email ON chaves(email, revogada_em);
