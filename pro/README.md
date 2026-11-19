# WhatsBot Pro — instalador

Instala o WhatsBot Pro (repositório privado) no Coolify do aluno, com Postgres, domínio e HTTPS.
Ou, se o aluno preferir outro painel, só gera a chave de acesso ao código (opção 2 do menu; roda também em Mac e Windows com Git Bash).

```bash
bash <(curl -fsSL https://scripts.techify.site/whatsbot-pro)
```

Como funciona: o script gera uma chave SSH no servidor do aluno e manda só a chave **pública** e o e-mail a um
Worker da Cloudflare. Se o e-mail estiver liberado na base (D1), o Worker cadastra a chave como *deploy key*
**somente leitura** no repositório privado. A chave privada nunca sai do servidor do aluno.

- `worker/src/whatsbot-pro.sh` — o script que o aluno roda (o Worker o serve em `/whatsbot-pro`).
- `worker/src/index.js` — Worker: `POST /pro/chave` (cadastra), `POST /pro/admin/revogar` (revoga).
- `worker/schema.sql` — tabelas `alunos` (limite de chaves por e-mail) e `chaves`.

Para publicar: crie o D1, ponha o id em `wrangler.jsonc`, aplique o `schema.sql` e grave os segredos
`GH_APP_ID`, `GH_APP_KEY` (PKCS#8) e `ADMIN_TOKEN` com `wrangler secret put`. O GitHub App precisa de
*Administration: write* e ser instalado **só** no repositório do produto. Depois, `wrangler deploy`.
