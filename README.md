# WhatsBot-Lite — instaladores

Scripts de uma linha para instalar o [WhatsBot-Lite](https://github.com/Techify-one/whatsbot-lite) em um servidor Linux limpo (Ubuntu ou Debian), rodando como `root`.

Escolha **um** dos três jeitos:

| Quero... | Comando |
|---|---|
| Rodar com **Docker**, em rede interna (acesso por `IP:porta`) | `bash <(curl -fsSL https://scripts.techify.site/whatsbot-docker)` |
| Rodar **direto no Linux**, sem Docker, como serviço | `bash <(curl -fsSL https://scripts.techify.site/whatsbot-linux)` |
| Usar **Coolify** com domínio e HTTPS automático | `bash <(curl -fsSL https://scripts.techify.site/whatsbot-coolify)` |

Sem `curl` no servidor? Troque `curl -fsSL` por `wget -qO-`.

> **Leia antes de rodar.** Estes scripts rodam como root. O código está neste repositório, em [`whatsbot-docker.sh`](whatsbot-docker.sh), [`whatsbot-linux.sh`](whatsbot-linux.sh) e [`whatsbot-coolify.sh`](whatsbot-coolify.sh). Se preferir, baixe, leia e só então execute: `curl -fsSL https://scripts.techify.site/whatsbot-docker -o instalar.sh && less instalar.sh && bash instalar.sh`.

## O que cada um faz

### Docker (`whatsbot-docker`)
Sem perguntas. Instala o Docker, baixa o WhatsBot-Lite em `/opt/whatsbot`, sobe o container e mostra o endereço `http://IP-DO-SERVIDOR:PORTA`. Usa a porta 8080, ou a próxima livre se ela estiver ocupada (`PORTA=8081` para escolher).

### Linux (`whatsbot-linux`)
Sem perguntas. Instala Python e dependências, baixa o código em `/opt/whatsbot-lite`, cria um usuário de sistema `whatsbot` e deixa o WhatsBot rodando como serviço `systemd` (sobe sozinho quando o servidor liga). Mostra o IP do servidor, não `localhost`.

### Coolify (`whatsbot-coolify`)
Faz quatro perguntas: domínio do WhatsBot, domínio do painel do Coolify (opcional), e-mail e senha do administrador. Antes de instalar, confere se o domínio já aponta para o IP do servidor e, se não apontar, espera e tenta de novo. Depois instala o Coolify, cria o WhatsBot dentro dele e espera os certificados HTTPS.

Antes de rodar:
- crie um registro DNS do tipo **A** do seu domínio para o IP público do servidor (no Cloudflare, deixe como **Somente DNS**, nuvem cinza);
- deixe as portas **80 e 443** abertas no firewall do provedor;
- o e-mail precisa ser real (o Coolify recusa domínios de e-mail que não existem);
- a senha precisa de 8+ caracteres com maiúscula, minúscula, número e símbolo. Sem senha, o script gera uma forte.

Sem terminal para responder (automação)? Defina as variáveis antes do comando:

```bash
DOMINIO=bot.exemplo.com EMAIL=voce@gmail.com SENHA='Sua-Senha-1!' \
  bash <(curl -fsSL https://scripts.techify.site/whatsbot-coolify)
```

## Sistemas recomendados

| Script | Recomendado | Observação |
|---|---|---|
| Docker e Coolify | Ubuntu 22.04, 24.04, 26.04 · Debian 12, 13 | as versões que o Docker suporta |
| Linux (sem Docker) | Ubuntu 24.04, 26.04 · Debian 12, 13 | o WhatsBot exige Python 3.11+; no Ubuntu 22.04 o script instala o 3.11 (pré-lançamento), então prefira a 24.04 |

Outra versão? O script avisa e pergunta se você quer continuar mesmo assim (`FORCAR=1` segue sem perguntar). Mínimo sugerido: 2 GB de RAM para Docker/Coolify (1 GB no Linux direto) e 10 GB livres.

## Pontos de atenção

- O painel do WhatsBot **não tem senha**: quem abrir o endereço entra. Mantenha em rede interna ou atrás de um proxy com login.
- No Coolify, o Let's Encrypt emite só **5 certificados por semana para o mesmo nome**. Reinstalar do zero várias vezes com o mesmo domínio esgota o limite.
- Rodar de novo o mesmo comando **atualiza** o WhatsBot e mantém os dados.

## Como este endereço funciona

`scripts.techify.site/<nome>` redireciona para o arquivo `<nome>.sh` na branch `main` deste repositório. Não há servidor próprio: o que você baixa é exatamente o que está aqui.
