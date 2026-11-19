#!/usr/bin/env bash
# =====================================================================
#  WhatsBot Pro — instalação no Coolify, ou só a chave de acesso ao código
#
#    bash <(curl -fsSL https://scripts.techify.site/whatsbot-pro)
#
#  A primeira pergunta escolhe o que fazer:
#    1) Instalar no Coolify (Ubuntu ou Debian, como root, só em servidor Linux)
#       Já tem o Coolify neste servidor: o script cria o Postgres e o WhatsBot Pro nele.
#       Não tem: o script instala o Coolify (e o Docker) antes.
#       Antes: aponte o domínio (registro A) para o IP público deste servidor
#       e deixe as portas 80 e 443 abertas no firewall.
#    2) Não instalar: só gera a chave SSH de acesso ao código (somente leitura) e mostra o endereço do
#       repositório, para usar em outro painel. Roda em Linux, macOS e Windows (Git Bash), sem root,
#       e pode baixar o código-fonte numa subpasta.
#
#  Sem perguntas (automação), defina as variáveis antes do comando:
#    [WHATSBOT_MODO=coolify|chave]  (sem ele e sem terminal: coolify)
#    WHATSBOT_EMAIL=voce@gmail.com  WHATSBOT_DOMINIO=pro.exemplo.com  [WHATSBOT_SENHA='...']
#    [WHATSBOT_DB_URL=postgresql://usuario:senha@host:5432/banco]  [WHATSBOT_NOME=whatsbot-pro]
#    [WHATSBOT_DOMINIO_PAINEL=coolify.exemplo.com]  [WHATSBOT_FORCAR=1]
#    Coolify ainda não instalado (obrigatório nesse caso): WHATSBOT_COOLIFY_EMAIL=voce@gmail.com  [WHATSBOT_COOLIFY_SENHA='...']
#    Modo chave: WHATSBOT_MODO=chave WHATSBOT_EMAIL=voce@gmail.com  [WHATSBOT_BAIXAR=1]  [WHATSBOT_PASTA=./whatsbot-pro]
# =====================================================================
set -Eeuo pipefail
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

API="${WHATSBOT_API:-https://scripts.techify.site}"
BRANCH="${WHATSBOT_BRANCH:-main}"
COOLIFY_VERSION="${WHATSBOT_COOLIFY_VERSION:-4.7.5}"   # usada só quando o Coolify ainda não existe
DNS_TIMEOUT="${WHATSBOT_DNS_TIMEOUT:-1800}"

EMAIL="${WHATSBOT_EMAIL:-}"
DOMINIO="${WHATSBOT_DOMINIO:-}"
DB_URL="${WHATSBOT_DB_URL:-}"
SENHA="${WHATSBOT_SENHA:-}"
NOME="${WHATSBOT_NOME:-whatsbot-pro}"
DOMINIO_PAINEL="${WHATSBOT_DOMINIO_PAINEL:-}"
COOLIFY_EMAIL="${WHATSBOT_COOLIFY_EMAIL:-}"   # login do Coolify (independe da compra); só vale quando o script instala o Coolify
COOLIFY_SENHA="${WHATSBOT_COOLIFY_SENHA:-}"
FORCAR="${WHATSBOT_FORCAR:-0}"
MODO=""                                   # coolify | chave (escolher_modo)
BAIXAR="${WHATSBOT_BAIXAR:-}"             # modo chave: 1 = baixa o código sem perguntar
PASTA="${WHATSBOT_PASTA:-}"               # modo chave: pasta do código (padrão: ./whatsbot-pro)

TOKEN_NAME=whatsbot-pro-provision
PROJETO="WhatsBot Pro"
CHAVES_DIR=/root/.whatsbot-pro
ACESSO=""
APT="apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
REGEX_DOMINIO='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}$'
IP4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
COOLIFY_NOVO=0
APT_OUT=""
CAPI_TOKEN=""
API_ORIG=""
APP_UUID=""
ADMIN_RESOLVIDO=0   # 1 = já existe usuário no Pro
ADMIN_APLICADO=0    # 1 = o administrador é o desta execução (senha confere)
PAINEL_OK=0
SENHA_GERADA=0
COOLIFY_SENHA_GERADA=0
NQ=0               # número da pergunta na tela

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mAviso:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

have_tty()  { { : </dev/tty; } 2>/dev/null; }
port_busy() { ss -ltn "( sport = :$1 )" 2>/dev/null | awk 'NR>1' | grep -q .; }
local_ip()  { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true; }
public_ip() {
  local u p
  for u in https://ifconfig.io https://api.ipify.org https://checkip.amazonaws.com https://icanhazip.com; do
    p=$(curl -4fsS -m 8 "$u" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$p" =~ $IP4_RE ]]; then printf '%s' "$p"; return 0; fi
  done
  return 0
}
psql_c() { docker exec -i coolify-db psql -q -U coolify -d coolify -v ON_ERROR_STOP=1 -tA "$@"; }

doh() {  # doh NOME TIPO_NUMERICO — DNS pelo resolvedor público, o que o Let's Encrypt enxerga
  curl -fsS -m 10 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=$1&type=$2" 2>/dev/null \
    | jq -r --argjson t "$2" '.Answer[]? | select(.type==$t) | .data' 2>/dev/null || true
}

# Portátil: este trecho roda também no bash 3.2 do macOS e no Git Bash do Windows (sem jq, sem ${x,,}, sem sha256sum).
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
# jget CAMPO JSON -> valor de um campo de texto do JSON plano que o Worker devolve (sem aspas escapadas).
jget() { printf '%s' "$2" | sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' | head -n1; }

# Instalar o Coolify só faz sentido num servidor Linux: nada de macOS, Windows (Git Bash) ou WSL.
servidor_linux() {
  [ "$(uname -s 2>/dev/null)" = Linux ] || return 1
  ! grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
}
plataforma() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo "um Mac" ;;
    MINGW*|MSYS*|CYGWIN*) echo "um Windows" ;;
    Linux) if servidor_linux; then echo "um Linux"; else echo "um Windows (WSL)"; fi ;;
    *) echo "outro sistema" ;;
  esac
}

# Primeira pergunta: instalar (Coolify) ou só gerar a chave de acesso ao código.
escolher_modo() {
  local r="" def=1
  servidor_linux || def=2
  case "${WHATSBOT_MODO:-}" in
    coolify|chave) MODO=$WHATSBOT_MODO ;;
    "") ;;
    *) die "WHATSBOT_MODO: use coolify ou chave." ;;
  esac
  # Quem já automatizava a instalação (domínio ou dados do Coolify por variável) não ganha pergunta nova.
  if [ -z "$MODO" ] && { [ -n "$DOMINIO" ] || [ -n "$DOMINIO_PAINEL" ] || [ -n "$COOLIFY_EMAIL" ]; }; then MODO=coolify; fi
  if [ -z "$MODO" ]; then
    if have_tty; then
      printf '\n\033[1;32m  WhatsBot Pro\033[0m\n\n  O que você quer fazer?\n\n'
      printf '    1) Instalar o WhatsBot Pro neste servidor Linux (no Coolify; se não houver, eu instalo)\n'
      printf '    2) Não quero instalar: só gerar a minha chave de acesso ao código\n\n'
      while :; do
        read -r -p "  Digite 1 ou 2 [$def]: " r </dev/tty
        case "${r:-$def}" in
          1) MODO=coolify ;;
          2) MODO=chave ;;
          *) printf '    digite 1 ou 2.\n' >&2; continue ;;
        esac
        if [ "$MODO" = coolify ] && ! servidor_linux; then
          printf '    A instalação só funciona em servidor Linux (Ubuntu ou Debian); isto é %s.\n' "$(plataforma)" >&2
          printf '    Digite 2 para gerar só a chave de acesso e instale depois no seu servidor.\n' >&2
          MODO=""; continue
        fi
        break
      done
    else
      MODO=coolify   # sem terminal e sem WHATSBOT_MODO: como sempre foi
    fi
  fi
  if [ "$MODO" = coolify ] && ! servidor_linux; then
    die "a instalação só funciona em servidor Linux (Ubuntu ou Debian); isto é $(plataforma). Use WHATSBOT_MODO=chave para gerar só a chave."
  fi
}

confirmar_continuar() {
  if [ "$FORCAR" = 1 ]; then return 0; fi
  if ! have_tty; then warn "sem terminal para perguntar; seguindo mesmo assim."; return 0; fi
  local r=""
  read -r -p "    Continuar mesmo assim? [s/N] " r </dev/tty
  case "$r" in s|S|sim|SIM|y|Y) return 0 ;; *) die "instalação cancelada." ;; esac
}

# ---------------------------------------------------------------- servidor

verificar_servidor() {
  local nome=${PRETTY_NAME:-desconhecido}
  case "${ID:-?}" in ubuntu|debian) info "Sistema: $nome" ;; *) warn "$nome: só Ubuntu e Debian foram testados."; confirmar_continuar ;; esac
  case "$(uname -m)" in x86_64|aarch64) ;; *) warn "arquitetura $(uname -m): só x86_64 e arm64 têm o motor do WhatsApp (GOWA)."; confirmar_continuar ;; esac
  local mem disk
  mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  disk=$(df -Pm / | awk 'NR==2{print $4}')
  # A construção da imagem do Pro usa ~350 MB a mais que o servidor em repouso (medido em 4 GB de RAM).
  if [ "$mem" -lt 2000 ];   then warn "só ${mem} MB de RAM; o recomendado são 4096 MB ou mais (a construção da imagem pode falhar)."; fi
  if [ "$disk" -lt 20000 ]; then warn "só ${disk} MB livres em /; o recomendado são 30 GB ou mais."; fi
  return 0
}

apt_update() {
  local i
  for i in $(seq 1 30); do
    if APT_OUT=$($APT update 2>&1); then return 0; fi
    if grep -qiE "Could not get lock|Unable to acquire the dpkg|is another process using it" <<<"$APT_OUT"; then
      if [ "$i" = 1 ]; then info "outro processo está usando o apt; aguardando..."; fi
      sleep 10
    else
      return 1
    fi
  done
  return 1
}

http_ok() {
  if command -v curl >/dev/null 2>&1; then curl -fsI -m 15 "$1" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then wget -q --spider -T 15 "$1"
  else return 0; fi
}

# Ubuntu intermediário (ex.: 24.10) sai de suporte e some do archive.ubuntu.com. Só mexe quando o erro é
# exatamente "o codinome desta máquina não tem mais Release" e o old-releases tem esse codinome.
corrigir_apt_ubuntu_antigo() {
  [ "${ID:-}" = ubuntu ] && [ -n "${VERSION_CODENAME:-}" ] || return 1
  grep -qE "The repository '[^']*(archive|security)\.ubuntu\.com[^']* ${VERSION_CODENAME}[a-z-]* Release' (no longer has|does not have) a Release file" <<<"$APT_OUT" || return 1
  http_ok "http://old-releases.ubuntu.com/ubuntu/dists/${VERSION_CODENAME}/Release" || return 1
  warn "o Ubuntu ${VERSION_ID:-} saiu de suporte; usando o arquivo old-releases.ubuntu.com (cópia das fontes originais em *.bak-whatsbot)."
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    grep -q 'ubuntu\.com/ubuntu' "$f" || continue
    if [ ! -e "$f.bak-whatsbot" ]; then cp -a "$f" "$f.bak-whatsbot"; fi
    sed -i -E 's#https?://(archive|security|[a-z]{2}\.archive)\.ubuntu\.com/ubuntu#http://old-releases.ubuntu.com/ubuntu#g' "$f"
  done
  return 0
}

restaurar_apt() {
  local b
  for b in /etc/apt/sources.list.bak-whatsbot /etc/apt/sources.list.d/*.bak-whatsbot; do
    [ -f "$b" ] && mv -f "$b" "${b%.bak-whatsbot}"
  done
  return 0
}

apt_preparar() {
  export DEBIAN_FRONTEND=noninteractive
  if ! apt_update; then
    if ! { corrigir_apt_ubuntu_antigo && apt_update; }; then
      restaurar_apt
      printf '%s\n' "$APT_OUT" | tail -6 >&2
      die "o apt não conseguiu atualizar a lista de pacotes (veja acima)."
    fi
  fi
  $APT install -y -qq ca-certificates curl wget git jq openssl iproute2 python3 openssh-client >/dev/null
}

# ---------------------------------------------------------------- perguntas

# Qualquer caractere imprimível, sem espaço. A senha só passa por jq (variável de ambiente) e pelo argon2 do Pro: não há o que escapar.
REGRA_SENHA="8 a 64 caracteres, sem espaço, com maiúscula, minúscula, número e um símbolo (ex.: # @ ! - _)"
valid_password() {
  [[ ${#1} -ge 8 && ${#1} -le 64 && $1 =~ ^[[:graph:]]+$ && $1 =~ [[:upper:]] && $1 =~ [[:lower:]] && $1 =~ [[:digit:]] && $1 =~ [^[:alnum:]] ]]
}
# O install.sh do Coolify grava a senha num .env: com $, &, #, aspas ou espaço ele descarta o usuário em silêncio.
REGRA_SENHA_CF='8 a 64 caracteres com maiúscula, minúscula, número e um símbolo de !@%^*_+=.,:?- (sem espaço, $, &, # ou aspas)'
valid_password_cf() {
  [[ ${#1} -ge 8 && ${#1} -le 64 && $1 =~ ^[A-Za-z0-9!@%^*_+=.,:?-]+$ && $1 =~ [A-Z] && $1 =~ [a-z] && $1 =~ [0-9] && $1 =~ [!@%^*_+=.,:?-] ]]
}
gerar_senha() { printf '%sAa1!' "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-14)"; }

email_fmt() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }   # só o formato (o modo chave não usa DNS nem jq)
email_ok() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || return 1
  [ -n "$(doh cloudflare.com 1)" ] || return 0
  local d=${1#*@}
  [ -n "$(doh "$d" 15)" ] || [ -n "$(doh "$d" 1)" ]
}
ck_dominio_pro() { ck_dominio "$1" && { [ -z "$DOMINIO_PAINEL" ] || [ "$1" != "$DOMINIO_PAINEL" ]; }; }
ck_dominio() { [[ "$1" =~ $REGEX_DOMINIO ]]; }
ck_dom_opc() { [ -z "$1" ] || [[ "$1" =~ $REGEX_DOMINIO ]]; }
ck_db_opc()  { [ -z "$1" ] || [[ "$1" =~ ^postgres(ql)?(\+psycopg)?://[^[:space:]]+@[^[:space:]]+/[^[:space:]]+$ ]]; }
ck_nome()    { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]]; }

perguntar() {  # perguntar VAR "texto" validador "erro"
  local var=$1 prompt=$2 check=$3 err=$4 val=""
  if [ -n "${!var:-}" ]; then "$check" "${!var}" || die "$err"; return 0; fi
  if ! have_tty; then
    if "$check" ""; then return 0; fi
    die "sem terminal para perguntar. Defina WHATSBOT_$var antes do comando."
  fi
  while :; do
    read -r -p "$prompt" val </dev/tty
    if "$check" "$val"; then printf -v "$var" '%s' "$val"; return 0; fi
    printf '    %s\n' "$err" >&2
  done
}

# perguntar_senha VAR FLAG_GERADA VALIDADOR "regra" "texto". Enter (ou sem terminal) = gera uma.
perguntar_senha() {
  local var=$1 flag=$2 check=$3 regra=$4 prompt=$5 s1="" s2=""
  printf -v "$flag" '%s' 0
  if [ -z "${!var}" ] && have_tty; then
    while :; do
      read -r -s -p "$prompt" s1 </dev/tty; echo >&2
      [ -n "$s1" ] || break
      if ! "$check" "$s1"; then printf '    senha inválida: use %s.\n' "$regra" >&2; continue; fi
      read -r -s -p "     Repita a senha: " s2 </dev/tty; echo >&2
      if [ "$s1" = "$s2" ]; then break; fi
      printf '    as senhas não conferem.\n' >&2
    done
    printf -v "$var" '%s' "$s1"
  fi
  if [ -z "${!var}" ]; then printf -v "$var" '%s' "$(gerar_senha)"; printf -v "$flag" '%s' 1; fi
  "$check" "${!var}" || die "senha inválida: use $regra."
}

# Servidor sem Coolify: estas perguntas vêm primeiro, o Coolify é instalado, e só depois entram as da compra e do Pro.
perguntas_coolify() {
  printf '\n\033[1;32m  WhatsBot Pro no Coolify\033[0m\n'
  printf '  Este servidor ainda não tem o Coolify: ele será instalado primeiro.\n'
  printf '  O login do Coolify é independente da compra: use qualquer e-mail real seu.\n'
  printf '  Os domínios precisam já apontar para este servidor.\n\n'
  perguntar DOMINIO_PAINEL "  $((++NQ))) Domínio do painel do Coolify (opcional; Enter = acessar por IP:8000): " ck_dom_opc \
    "domínio inválido. Use só o nome ou deixe vazio."
  # O Coolify só cria o administrador se o e-mail tiver domínio com DNS (MX ou A).
  perguntar COOLIFY_EMAIL "  $((++NQ))) E-mail de login do Coolify (real, ex.: voce@gmail.com): " email_ok \
    "e-mail inválido, ou o domínio dele não existe no DNS (o Coolify recusaria o cadastro)."
  COOLIFY_EMAIL=$(lower "$COOLIFY_EMAIL")
  perguntar_senha COOLIFY_SENHA COOLIFY_SENHA_GERADA valid_password_cf "$REGRA_SENHA_CF" \
    "  $((++NQ))) Senha do Coolify (Enter = gerar uma; ou $REGRA_SENHA_CF): "
}

fazer_perguntas() {
  if [ "$COOLIFY_NOVO" = 1 ]; then printf '\n\033[1;32m  Agora, o WhatsBot Pro\033[0m\n'
  else printf '\n\033[1;32m  WhatsBot Pro no Coolify\033[0m\n'; fi
  printf '  O domínio precisa já apontar para este servidor.\n\n'
  perguntar EMAIL "  $((++NQ))) Seu e-mail (o mesmo da compra): " email_ok \
    "e-mail inválido, ou o domínio dele não existe no DNS."
  EMAIL=$(lower "$EMAIL")
  perguntar DOMINIO "  $((++NQ))) Domínio do WhatsBot Pro (ex.: pro.seudominio.com): " ck_dominio_pro \
    "domínio inválido (use só o nome, sem http:// e sem barra) ou igual ao do painel do Coolify."
  perguntar DB_URL "  $((++NQ))) URL de um Postgres externo (opcional; Enter = criar um Postgres aqui): " ck_db_opc \
    "use o formato postgresql://usuario:senha@host:5432/banco ou deixe vazio."
  ck_nome "$NOME" || die "WHATSBOT_NOME: use 2 a 31 letras minúsculas, números ou hífen."
  perguntar_senha SENHA SENHA_GERADA valid_password "$REGRA_SENHA" \
    "  $((++NQ))) Senha do administrador do Pro (Enter = gerar uma; ou $REGRA_SENHA): "
  # postgres:// e postgresql:// -> o driver que o Pro usa
  if [ -n "$DB_URL" ]; then DB_URL=$(sed -E 's#^postgres(ql)?(\+psycopg)?://#postgresql+psycopg://#' <<<"$DB_URL"); fi
}

# Postgres externo: falha aqui, em segundos, em vez de depois de 6 a 11 minutos de build.
# O banco SQL_ASCII conecta e cria as tabelas, mas o app quebra no 1º start (SQLAlchemy não decodifica a versão).
# Os dados de conexão vão por variáveis PG*, não por argv: a senha não aparece no ps.
checar_db_externo() {
  [ -n "$DB_URL" ] || return 0
  step "Conferindo o Postgres externo"
  command -v psql >/dev/null 2>&1 || $APT install -y -qq postgresql-client >/dev/null
  local out rc=0 enc priv
  out=$(DB_URL="$DB_URL" python3 -I - 2>&1 <<'PY'
import os, sys
from urllib.parse import urlsplit, unquote, parse_qsl
try:
    u = urlsplit(os.environ["DB_URL"].replace("postgresql+psycopg://", "postgresql://", 1))
    porta = u.port or 5432
except ValueError:
    sys.exit("a porta da URL não é um número.")
e = dict(os.environ, PGHOST=u.hostname or "", PGPORT=str(porta), PGUSER=unquote(u.username or ""),
         PGPASSWORD=unquote(u.password or ""), PGDATABASE=unquote(u.path.lstrip("/")), PGCONNECT_TIMEOUT="10")
for k, v in parse_qsl(u.query):
    if k == "sslmode": e["PGSSLMODE"] = v
os.execvpe("psql", ["psql", "-X", "-qtA", "-F", "|", "-c",
    "select current_setting('server_encoding'), has_schema_privilege(current_user, current_schema(), 'CREATE')"], e)
PY
  ) || rc=$?
  [ "$rc" = 0 ] || die "não consegui usar o Postgres informado: $(head -n1 <<<"$out")
    Confira usuário, senha, host, porta e nome do banco (o banco precisa já existir) e se este servidor ($IP) tem acesso liberado."
  enc=${out%%|*}; priv=${out##*|}
  [ "$enc" = UTF8 ] || die "o banco informado usa a codificação $enc; o WhatsBot Pro exige UTF8.
    Crie outro banco assim:  CREATE DATABASE whatsbot TEMPLATE template0 ENCODING 'UTF8';"
  [ "$priv" = t ] || die "o usuário do banco não pode criar tabelas no schema padrão (public). Dê a permissão (GRANT CREATE ON SCHEMA public TO usuario) ou use o dono do banco."
  info "Postgres externo ok (UTF8, com permissão para criar tabelas)"
}

# ---------------------------------------------------------------- DNS e alcance

aguardar_dns() {  # $1 = domínio  $2 = IP público deste servidor
  local d=$1 ip=$2 t0=$SECONDS got last="" msg
  info "conferindo $d"
  while :; do
    if [ -n "$(doh cloudflare.com 1)" ]; then got=$(doh "$d" 1 | awk 'NR==1')
    else got=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}' || true); fi
    if [ "$got" = "$ip" ]; then
      info "DNS ok: $d -> $ip"
      local aaaa; aaaa=$(doh "$d" 28 | awk 'NR==1')
      if [ -n "$aaaa" ]; then warn "$d também tem um registro AAAA (IPv6: $aaaa). Se este servidor não responde em IPv6, o certificado falha."; fi
      return 0
    fi
    if [ -z "$got" ]; then msg="$d ainda não existe no DNS. Crie um registro A para $ip."
    else msg="$d aponta para $got, mas este servidor é $ip. Se usa Cloudflare, deixe o registro como \"Somente DNS\" (nuvem cinza)."; fi
    if [ "$msg" != "$last" ]; then printf '    %s\n    aguardando... (Ctrl+C cancela; depois de corrigir é só esperar)\n' "$msg"; last=$msg; fi
    if [ $((SECONDS - t0)) -ge "$DNS_TIMEOUT" ]; then die "o DNS de $d não apontou para $ip em $((DNS_TIMEOUT / 60)) minutos. Corrija o registro e rode o comando de novo."; fi
    sleep 10
  done
}

# Só com porta 80 livre (Coolify ainda não instalado): prova que o nome chega aqui, como o Let's Encrypt fará.
testar_porta80() {
  local d=$1 dir tok pid ok=1 i
  dir=$(mktemp -d); tok=$(openssl rand -hex 8); echo "ok-$tok" > "$dir/$tok"
  (cd "$dir" && exec python3 -m http.server 80 --bind 0.0.0.0 >/dev/null 2>&1) &
  pid=$!
  sleep 1
  for i in 1 2 3 4 5 6; do
    if [ "$(curl -fsS -m 8 "http://$d/$tok" 2>/dev/null || true)" = "ok-$tok" ]; then ok=0; break; fi
    sleep 5
  done
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -rf "$dir"
  return $ok
}

aguardar_cert() {
  local i iss
  for i in $(seq 1 36); do
    iss=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$1" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)
    if [[ "$iss" == *"Let's Encrypt"* ]]; then return 0; fi
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------- Coolify (instalação nova)

exigir_portas_livres() {
  local p
  for p in 80 443 8000 6001 6002; do
    if port_busy "$p"; then die "a porta $p já está em uso neste servidor (o Coolify precisa de 80, 443, 8000, 6001 e 6002 livres)."; fi
  done
}

instalar_coolify() {
  export USER=root
  local tmp i ok=0; tmp="$(mktemp -d)"
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o "$tmp/install.sh"
  # O install.sh do Coolify tem tempo limite (60 s para ficar saudável, 180 s para subir): em servidor lento ele desiste mesmo
  # com tudo certo, às vezes com o container do Coolify criado mas PARADO. Se o container existe, inicia-o (se estiver parado)
  # e espera o Coolify responder (até 6 min, logo abaixo); se nem existe, falha já.
  if ! ROOT_USERNAME=admin ROOT_USER_EMAIL="$COOLIFY_EMAIL" ROOT_USER_PASSWORD="$COOLIFY_SENHA" AUTOUPDATE=false \
      bash "$tmp/install.sh" "$COOLIFY_VERSION"; then
    { command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -qx coolify; } \
      || die "o instalador do Coolify falhou antes de subir o Coolify (veja as mensagens acima)."
    warn "o instalador do Coolify desistiu por tempo (comum em servidor lento); vou conferir se o Coolify subiu."
    if ! docker ps --format '{{.Names}}' | grep -qx coolify; then
      info "o container do Coolify estava criado mas parado; iniciando."
      docker start coolify >/dev/null || die "não consegui iniciar o container do Coolify. Veja: docker logs coolify"
    fi
  fi
  rm -rf "$tmp"
  step "Esperando o Coolify responder"
  for i in $(seq 1 90); do
    if curl -fsS -m 5 http://127.0.0.1:8000/api/health >/dev/null 2>&1; then ok=1; break; fi
    sleep 4
  done
  if [ "$ok" != 1 ]; then docker ps -a; die "o Coolify não respondeu em /api/health após 6 minutos."; fi
  # O administrador só nasce quando as ~520 migrações do banco terminam: com o disco lento isso passa de 2 minutos (medido: ~6).
  for i in $(seq 1 150); do
    if [ "$(psql_c -c 'select count(*) from users where id = 0' 2>/dev/null || true)" = 1 ]; then break; fi
    sleep 4
  done
  [ "$(psql_c -c 'select count(*) from users where id = 0')" = 1 ] \
    || die "o administrador do Coolify não foi criado (e-mail sem domínio real?). Veja: docker logs coolify | grep -A3 'Invalid Root User'"
  umask 077
  { echo "Coolify:   http://$IP:8000"; echo "E-mail:    $COOLIFY_EMAIL"; echo "Senha:     $COOLIFY_SENHA"; } > /root/coolify-acesso.txt
  info "Coolify instalado. Login: $COOLIFY_EMAIL (dados em /root/coolify-acesso.txt, só o root lê)."
  if [ "$COOLIFY_SENHA_GERADA" = 1 ]; then info "Senha do Coolify (gerada agora): $COOLIFY_SENHA"; fi
}

# O install.sh do Coolify grava a porta SSH 22; com o sshd em outra porta o deploy falha.
ajustar_porta_ssh() {
  local ports p
  ports=$(ss -ltnpH 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}' | sort -un || true)
  if [ -z "$ports" ]; then ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' || true); fi
  p=$(head -n1 <<<"$ports")
  grep -qx 22 <<<"$ports" && p=22
  [[ "$p" =~ ^[0-9]+$ ]] || p=22
  if [ "$p" != 22 ]; then
    info "o SSH deste servidor está na porta $p; avisando o Coolify."
    psql_c -c "UPDATE servers SET port = $p WHERE id = 0" >/dev/null
  fi
}

painel_dominio() {  # $1 = domínio
  local d=$1 out
  out=$(docker exec -u www-data -e DASH_FQDN="https://$d" coolify php artisan tinker --execute='
$s = instanceSettings();
$s->fqdn = getenv("DASH_FQDN");
$s->save();
\App\Models\Server::findOrFail(0)->setupDynamicProxyConfiguration();
echo "DASH_OK ".instanceSettings()->fqdn.PHP_EOL;' 2>&1 || true)
  if grep -q "DASH_OK https://$d" <<<"$out"; then info "painel configurado em https://$d"
  else warn "não consegui configurar o domínio do painel; ele continua em http://$IP:8000."; return 1; fi
}

# ---------------------------------------------------------------- chave de acesso ao código

# Uma chave por e-mail neste servidor, reaproveitada nas próximas execuções (vários WhatsBot Pro, mesma chave).
gerar_e_registrar_chave() {
  local h; h=$(printf '%s' "$EMAIL" | sha256 | cut -c1-8)
  KEY="$CHAVES_DIR/chave-$h"
  umask 077; mkdir -p "$CHAVES_DIR"
  KEY_NOVA=0
  if [ ! -s "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "whatsbot-pro $EMAIL" -f "$KEY"
    KEY_NOVA=1
  elif [ ! -s "$KEY.pub" ]; then
    # Chave privada copiada de outra máquina, sem a pública. Zip/pendrive/scp costumam deixá-la com permissão aberta (o ssh recusa).
    chmod 600 "$KEY" 2>/dev/null || true
    ssh-keygen -y -f "$KEY" > "$KEY.pub" 2>/dev/null \
      || { rm -f "$KEY.pub"; die "a chave $KEY não pôde ser lida (arquivo inválido ou com senha). Mude o nome dela e rode de novo para gerar outra."; }
  fi
  # JSON à mão (sem jq, que o Mac e o Git Bash do Windows não têm): o e-mail já passou na regex (sem aspas nem barras),
  # a chave pública é base64 e o nome da máquina é limpo.
  local resp code body maq
  maq=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9.-' | cut -c1-40 || true)
  # Só "ssh-ed25519 <base64>": o comentário da chave (pode ter aspas ou barra) quebraria o JSON e o Worker não precisa dele.
  resp=$(printf '{"email":"%s","chave_publica":"%s","maquina":"%s"}' "$EMAIL" "$(tr -d '\r\n' < "$KEY.pub" | cut -d' ' -f1,2)" "${maq:-pc}" \
    | curl -sS -m 30 -w '\n%{http_code}' -X POST "$API/pro/chave" -H 'Content-Type: application/json' --data-binary @- ) \
    || die "não consegui falar com $API. Confira a internet."
  code=${resp##*$'\n'}; body=${resp%$'\n'*}
  if [ "$code" != 200 ]; then
    [ "$KEY_NOVA" = 1 ] && rm -f "$KEY" "$KEY.pub"
    local msg; msg=$(jget erro "$body")
    warn "${msg:-resposta inesperada (HTTP $code)}"
    local c; c=$(jget contato "$body")
    [ -z "$c" ] || info "Fale com a Techify: $c"
    die "não foi possível liberar o acesso ao código."
  fi
  REPO=$(jget repositorio "$body")
  CONTATO=$(jget contato "$body")
  [ -n "$REPO" ] || die "resposta do servidor sem o endereço do repositório."
  # No modo chave a chave é o objetivo: aparece sempre (com terminal). No modo Coolify, só quando é nova.
  if [ "$KEY_NOVA" = 1 ] || [ "$MODO" = chave ]; then
    echo
    echo "  ----------------------------------------------------------------"
    echo "  Chave de acesso ao código do WhatsBot Pro (GUARDE, não perca):"
    echo "  Arquivo: $KEY"
    # Sem terminal (automação, CI) a chave privada iria parar num log: lá só o caminho.
    if have_tty; then
      echo
      cat "$KEY"
    fi
    echo "  ----------------------------------------------------------------"
    if [ "$KEY_NOVA" = 1 ] && have_tty && [ "$FORCAR" != 1 ]; then
      local r=""
      while [ "$r" != guardei ]; do read -r -p "  Copie a chave acima para um lugar seguro e digite 'guardei': " r </dev/tty; done
    fi
  else
    info "chave de acesso reaproveitada: $KEY"
  fi
}

# ---------------------------------------------------------------- modo "só a chave"

# Sem root, sem apt, sem Docker, sem DNS: roda no Linux, no macOS e no Git Bash do Windows.
modo_chave() {
  CHAVES_DIR="${HOME:-.}/.whatsbot-pro"   # root: /root/.whatsbot-pro, a mesma pasta do modo Coolify
  local f
  for f in ssh-keygen curl tr sed; do
    command -v "$f" >/dev/null 2>&1 || die "preciso do comando '$f'. Instale o OpenSSH (Windows: o Git for Windows já traz) e rode de novo."
  done
  printf '\n\033[1;32m  Chave de acesso ao código do WhatsBot Pro\033[0m\n'
  printf '  Vou gerar uma chave SSH só sua, somente leitura, e mostrar o endereço do repositório.\n'
  printf '  Com ela você instala no painel que quiser (Coolify, Dokploy...) ou baixa o código.\n\n'
  perguntar EMAIL "  1) Seu e-mail (o mesmo da compra): " email_fmt "e-mail inválido."
  EMAIL=$(lower "$EMAIL")

  step "Liberando o acesso ao código"
  gerar_e_registrar_chave

  local arq
  arq="$CHAVES_DIR/acesso-chave-$(basename "$KEY" | sed 's/^chave-//').txt"   # um por e-mail: outro e-mail não apaga o anterior
  umask 077
  {
    echo "Repositório:    $REPO"
    echo "Chave privada:  $KEY"
    echo "E-mail:         $EMAIL"
  } > "$arq"

  baixar_codigo || true

  printf '\n\033[1;32mPronto!\033[0m\n\n'
  echo "  Repositório (SSH):  $REPO"
  echo "  Chave privada:      $KEY"
  echo "  Estes dados:        $arq"
  [ -z "${CODIGO_DIR:-}" ] || echo "  Código-fonte em:    $CODIGO_DIR"
  cat <<EOF

  No painel onde for instalar, cadastre a chave privada (o conteúdo do arquivo acima) e use o endereço do repositório.
  Para ver o código-fonte ou pedir ajuda, fale com a Techify${CONTATO:+: $CONTATO}.
EOF
}

# Baixa o código para uma SUBPASTA (nunca despeja arquivos na pasta onde o comando foi dado). Pasta que já é o repositório: atualiza.
baixar_codigo() {
  CODIGO_DIR=""
  local r="" dest="${PASTA:-whatsbot-pro}" quer=0 ssh_cmd
  if [ "$BAIXAR" = 1 ]; then quer=1
  elif [ -z "$BAIXAR" ] && have_tty; then
    read -r -p "  Baixar o código-fonte agora, numa pasta deste computador? [s/N] " r </dev/tty
    case "$r" in s|S|sim|SIM|y|Y) quer=1 ;; esac
  fi
  [ "$quer" = 1 ] || return 0
  if ! command -v git >/dev/null 2>&1; then
    warn "o Git não está instalado, então não baixei o código. Instale o Git (Windows: https://git-scm.com/download/win) e rode de novo."
    return 1
  fi
  if [ -z "$PASTA" ] && have_tty; then
    read -r -p "  Em qual pasta? (Enter = ./whatsbot-pro, dentro de $(pwd)): " r </dev/tty
    [ -z "$r" ] || dest=$r
  fi
  # shellcheck disable=SC2088  # o til é o texto que o aluno digita: nem o read nem a variável o expandem
  case "$dest" in "~") dest=$HOME ;; "~/"*) dest="$HOME/${dest#\~/}" ;; esac
  case "$dest" in -*) dest="./$dest" ;; esac   # pasta que começa com '-' viraria opção do git
  local kq="${KEY//\'/\'\\\'\'}"               # apóstrofo no caminho (C:\Users\O'Brien) quebraria as aspas do comando
  ssh_cmd="ssh -i '$kq' -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  if [ -d "$dest/.git" ] && [ "$(git -C "$dest" remote get-url origin 2>/dev/null || true)" = "$REPO" ]; then
    step "A pasta $dest já é o repositório: atualizando"
    ( umask 022; GIT_SSH_COMMAND="$ssh_cmd" git -C "$dest" pull --ff-only ) || { warn "não consegui atualizar $dest."; return 1; }
  elif [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null || true)" ]; then
    warn "a pasta '$dest' já existe e não está vazia. Escolha outra (WHATSBOT_PASTA=outra-pasta) ou apague-a."
    return 1
  else
    step "Baixando o código para $dest"
    ( umask 022; GIT_SSH_COMMAND="$ssh_cmd" git clone --branch "$BRANCH" "$REPO" "$dest" ) || { warn "o download falhou. Veja a mensagem acima."; return 1; }
  fi
  CODIGO_DIR=$(cd "$dest" && pwd)
}

# ---------------------------------------------------------------- Coolify (API)

api_cleanup() {
  [ -n "$CAPI_TOKEN" ] || return 0
  psql_c -c "DELETE FROM personal_access_tokens WHERE name = '$TOKEN_NAME'" >/dev/null 2>&1 || true
  psql_c -c "UPDATE instance_settings SET is_api_enabled = $([ "$API_ORIG" = t ] && echo true || echo false) WHERE id = 0" >/dev/null 2>&1 || true
}

capi() {  # capi METHOD PATH [JSON]
  local m=$1 p=$2 body=${3:-} out code
  out=$(curl -sS -X "$m" -H "Authorization: Bearer $CAPI_TOKEN" -H 'Accept: application/json' \
    ${body:+-H 'Content-Type: application/json' -d "$body"} -w '\n%{http_code}' "http://127.0.0.1:8000/api/v1$p") || return 1
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [[ "$code" != 2* ]]; then printf 'Coolify API %s %s -> HTTP %s: %s\n' "$m" "$p" "$code" "$(head -c 300 <<<"$out")" >&2; return 1; fi
  printf '%s' "$out"
}

abrir_api() {
  [ "$(psql_c -c 'select count(*) from users where id = 0' 2>/dev/null || true)" = 1 ] \
    || die "não achei o administrador principal do Coolify (usuário 0). Este instalador espera o Coolify padrão."
  API_ORIG=$(psql_c -c "select is_api_enabled from instance_settings where id = 0")
  CAPI_TOKEN=$(openssl rand -hex 24)
  trap api_cleanup EXIT
  psql_c <<SQL
UPDATE instance_settings SET is_api_enabled = true WHERE id = 0;
UPDATE teams SET show_boarding = false WHERE id = 0;
DELETE FROM personal_access_tokens WHERE name = '$TOKEN_NAME';
INSERT INTO personal_access_tokens (tokenable_type, tokenable_id, name, token, team_id, abilities, created_at, updated_at)
VALUES ('App\Models\User', 0, '$TOKEN_NAME', encode(sha256(convert_to('$CAPI_TOKEN', 'UTF8')), 'hex'), '0', '["root"]', now(), now());
SQL
}

# Container em execução do app (o do build antigo some quando o novo sobe; pega o mais recente).
container_app() { docker ps --format '{{.Names}}' | grep "^${APP_UUID}-" | sort | tail -n1 || true; }

# POST direto no container, sem DNS nem certificado no caminho. Imprime o código HTTP (vazio = sem container/sem resposta).
admin_http() {  # admin_http ROTA JSON
  local ctr; ctr=$(container_app)
  [ -n "$ctr" ] || return 0
  printf '%s' "$2" | docker exec -i "$ctr" curl -sS -m 8 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:8080$1" \
    -H 'Content-Type: application/json' --data-binary @- 2>/dev/null || true
}

# Cria o primeiro administrador. Quanto antes melhor: sem nenhum usuário o painel do Pro aceita qualquer pessoa.
# Retorna 0 quando resolvido (criado, ou já havia usuário), 1 quando o app ainda não respondeu.
admin_tentar() {
  local code
  code=$(admin_http /api/auth/bootstrap "$(SENHA="$SENHA" jq -nc --arg e "$EMAIL" --arg n "${EMAIL%%@*}" '{email: $e, name: $n, password: env.SENHA}')")
  case "$code" in
    200) ADMIN_APLICADO=1 ;;
    409) # já havia usuário: só vale como "nosso" se a senha informada entra
      [ "$(admin_http /api/auth/login "$(SENHA="$SENHA" jq -nc --arg e "$EMAIL" '{email: $e, password: env.SENHA}')")" = 200 ] && ADMIN_APLICADO=1 || true ;;
    *) return 1 ;;
  esac
  ADMIN_RESOLVIDO=1
}

criar_pro() {
  local server project kuuid kname dbu dbpass app d s i ok fqdn="https://$DOMINIO" v have falhas=0 atual motivo
  server=$(psql_c -c "select uuid from servers where id = 0")
  [ -n "$server" ] || die "servidor principal não encontrado no Coolify."

  info "esperando o proxy (Traefik)"
  for i in $(seq 1 90); do
    if [ "$(capi GET "/servers/$server/proxy" | jq -r .status)" = running ]; then break; fi
    sleep 2
  done

  project=$(capi GET /projects | jq -r --arg n "$PROJETO" 'first(.[] | select(.name == $n) | .uuid) // empty')
  [ -n "$project" ] || project=$(capi POST /projects "$(jq -nc --arg n "$PROJETO" '{name: $n}')" | jq -r .uuid)

  kname="whatsbot-pro-$(basename "$KEY" | sed 's/^chave-//')"
  kuuid=$(capi GET /security/keys | jq -r --arg n "$kname" 'first(.[] | select(.name == $n) | .uuid) // empty')
  if [ -z "$kuuid" ]; then
    kuuid=$(capi POST /security/keys "$(jq -nc --arg n "$kname" --arg k "$(cat "$KEY")" \
      '{name: $n, description: "Acesso somente leitura ao código do WhatsBot Pro", private_key: $k}')" | jq -r .uuid)
  fi

  if [ -n "$DB_URL" ]; then
    info "usando o Postgres externo informado"
  else
    # Reexecução: reaproveita o Postgres da tentativa anterior em vez de criar outro (e perder a senha dele).
    dbu=$(capi GET /databases | jq -r --arg n "$NOME-db" 'first(.[] | select(.name == $n) | .uuid) // empty')
    if [ -n "$dbu" ]; then
      info "reaproveitando o Postgres '$NOME-db' que já existe"
      dbpass=$(capi GET "/databases/$dbu" | jq -r '.postgres_password // empty')
      capi POST "/databases/$dbu/start" >/dev/null 2>&1 || true
    else
      step "Criando o Postgres"
      dbpass=$(openssl rand -hex 16)
      dbu=$(capi POST /databases/postgresql "$(jq -nc --arg p "$project" --arg s "$server" --arg pw "$dbpass" --arg n "$NOME-db" \
        '{project_uuid: $p, server_uuid: $s, environment_name: "production", name: $n, image: "postgres:17-alpine",
          postgres_user: "whatsbot", postgres_password: $pw, postgres_db: "whatsbot", instant_deploy: true}')" | jq -r .uuid)
    fi
    [ -n "$dbu" ] && [ "$dbu" != null ] && [ -n "$dbpass" ] || die "não consegui criar ou ler o Postgres no Coolify."
    ok=0
    for i in $(seq 1 60); do
      case "$(capi GET "/databases/$dbu" | jq -r .status)" in running*) ok=1; break ;; esac
      sleep 4
    done
    [ "$ok" = 1 ] || die "o Postgres não ficou pronto em 4 minutos. Veja no Coolify: $PROJETO > $NOME-db."
    DB_URL="postgresql+psycopg://whatsbot:$dbpass@$dbu:5432/whatsbot"
  fi

  app=$(capi GET /applications | jq -r --arg n "$NOME" 'first(.[] | select(.name == $n) | .uuid) // empty')
  if [ -z "$app" ]; then
    app=$(capi POST /applications/private-deploy-key "$(jq -nc \
      --arg p "$project" --arg s "$server" --arg k "$kuuid" --arg r "$REPO" --arg b "$BRANCH" --arg n "$NOME" --arg d "$fqdn" \
      '{project_uuid: $p, server_uuid: $s, environment_name: "production", private_key_uuid: $k, git_repository: $r, git_branch: $b,
        build_pack: "dockerfile", ports_exposes: "8080", name: $n, domains: $d, health_check_enabled: false, instant_deploy: false}')" | jq -r .uuid)
    [ -n "$app" ] && [ "$app" != null ] || die "o Coolify não criou o aplicativo."
  else
    info "o aplicativo '$NOME' já existe no Coolify; retomando de onde parou."
    atual=$(capi GET "/applications/$app" | jq -r '.fqdn // empty')
    [ "$atual" = "$fqdn" ] || die "o aplicativo '$NOME' existente usa '${atual:-nenhum domínio}', diferente de $fqdn. Use o mesmo domínio, ou WHATSBOT_NOME=outro-nome para criar outra instância."
  fi
  APP_UUID=$app

  # is_literal: um "$" na senha de um Postgres externo não pode ser interpolado pelo Coolify.
  have=$(capi GET "/applications/$app/envs" | jq -r '.[] | select(.is_preview == false) | .key')
  grep -qx DATABASE_URL <<<"$have" \
    || capi POST "/applications/$app/envs" "$(jq -nc --arg v "$DB_URL" '{key: "DATABASE_URL", value: $v, is_preview: false, is_literal: true}')" >/dev/null
  grep -qx WHATSBOT_PUBLIC_URL <<<"$have" \
    || capi POST "/applications/$app/envs" "$(jq -nc --arg v "$fqdn" '{key: "WHATSBOT_PUBLIC_URL", value: $v, is_preview: false, is_literal: true}')" >/dev/null

  # Sem volumes nomeados, cada redeploy começaria com /app/storages vazio (sessão do WhatsApp e arquivos).
  have=$(capi GET "/applications/$app/storages" | jq -r '.persistent_storages[].mount_path')
  for v in storages statics logs; do
    grep -qx "/app/$v" <<<"$have" \
      || capi POST "/applications/$app/storages" "$(jq -nc --arg n "$v" --arg m "/app/$v" '{type: "persistent", name: $n, mount_path: $m}')" >/dev/null
  done

  # Reexecução: acompanha o deploy que já está rodando, ou não reconstrói um app que já está no ar.
  d=$(psql_c -c "select deployment_uuid from application_deployment_queues where application_id = (select id::text from applications where uuid = '$app') and status in ('in_progress','queued') order by id desc limit 1")
  atual=$(capi GET "/applications/$app" | jq -r '.status // empty')
  if [ -n "$d" ]; then
    step "Acompanhando o deploy que já estava em andamento"
  elif [[ "$atual" == running* ]]; then
    info "o aplicativo já está no ar; não vou construir de novo."
    return 0
  else
    step "Construindo e publicando o WhatsBot Pro (3 a 8 minutos)"
    d=$(capi POST "/deploy?uuid=$app" '{}' | jq -r '.deployments[0].deployment_uuid')
    [ -n "$d" ] && [ "$d" != null ] || die "o deploy não entrou na fila."
  fi
  s=""
  for i in $(seq 1 400); do
    # O admin sai assim que o app responde, antes de o Traefik expor o endereço (ele só roteia depois do health check).
    if [ "$ADMIN_RESOLVIDO" != 1 ]; then admin_tentar || true; fi
    if s=$(capi GET "/deployments/$d" 2>/dev/null | jq -r .status 2>/dev/null) && [ -n "$s" ]; then
      falhas=0
      case $s in
        finished) break ;;
        failed|cancelled-by-user)
          motivo=$(capi GET "/deployments/$d" 2>/dev/null | jq -r '(.logs // "[]") | (if type == "string" then fromjson else . end)
            | map(select(.hidden == false and (.output | startswith("Deployment failed")))) | first | .output // empty' 2>/dev/null || true)
          if [ -n "$motivo" ]; then warn "$motivo"; fi
          die "o deploy terminou como '$s'. Veja no Coolify: $PROJETO > $NOME > Deployments. Corrigido o problema, rode o comando de novo: ele retoma daqui." ;;
      esac
    else
      s=""; falhas=$((falhas + 1))
      if [ "$falhas" -ge 40 ]; then die "a API do Coolify parou de responder (2 minutos). Veja: docker logs coolify --tail 30"; fi
    fi
    sleep 3
  done
  [ "$s" = finished ] || die "tempo esgotado esperando o deploy (último estado: $s)."
}

# Garante o administrador mesmo quando o app já estava no ar (reexecução) ou subiu sem ser visto durante o deploy.
criar_admin() {
  local i
  for i in $(seq 1 60); do
    if [ "$ADMIN_RESOLVIDO" = 1 ] || admin_tentar; then break; fi
    sleep 3
  done
  [ "$ADMIN_RESOLVIDO" = 1 ] || die "o WhatsBot Pro subiu, mas não consegui criar o administrador. Abra https://$DOMINIO e veja se pede o cadastro."
  if [ "$ADMIN_APLICADO" != 1 ]; then
    warn "o WhatsBot Pro já tinha um administrador e a senha informada não confere com ele. Entre com a senha do administrador que já existia."
  fi
}

# Logo depois do admin: se o script cair no certificado, a senha gerada não se perde.
gravar_acesso() {
  local url_painel="http://$IP:8000"
  if [ "$PAINEL_OK" = 1 ]; then url_painel="https://$DOMINIO_PAINEL"; fi
  ACESSO="/root/${NOME}-acesso.txt"
  umask 077
  {
    echo "WhatsBot Pro:   https://$DOMINIO"
    echo "Coolify:        $url_painel"
    echo "E-mail:         $EMAIL"
    if [ "$ADMIN_APLICADO" = 1 ]; then echo "Senha:          $SENHA"; else echo "Senha:          (já havia um administrador; use a senha dele)"; fi
    echo "Chave (código): $KEY"
    echo "Repositório:    $REPO"
  } > "$ACESSO"
  if [ "$ADMIN_APLICADO" = 1 ] && [ "$SENHA_GERADA" = 1 ]; then
    info "Senha do administrador (gerada agora): $SENHA   (também em $ACESSO)"
  fi
}

# ---------------------------------------------------------------- main

main() {
  escolher_modo
  if [ "$MODO" = chave ]; then modo_chave; return 0; fi

  [ "$(id -u)" -eq 0 ] || die "rode como root (use: sudo -i)"
  # shellcheck disable=SC1091
  . /etc/os-release

  step "Verificando o servidor"
  verificar_servidor
  step "Preparando o servidor"
  apt_preparar

  IP=$(public_ip); if [ -z "$IP" ]; then IP=$(local_ip); fi
  [ -n "$IP" ] || die "não consegui descobrir o IP deste servidor."
  info "IP público deste servidor: $IP"

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx coolify; then
    info "Coolify encontrado neste servidor: o WhatsBot Pro será criado nele."
  else
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qE '^coolify($|-)' || [ -d /data/coolify/source ]; then
      die "há sobras de um Coolify parado neste servidor. Inicie-o (docker start coolify coolify-db coolify-redis) ou limpe antes de continuar."
    fi
    COOLIFY_NOVO=1
    info "Coolify não encontrado: ele será instalado junto."
  fi

  PAINEL_OK=0
  if [ "$COOLIFY_NOVO" = 1 ]; then
    perguntas_coolify
    if [ -n "$DOMINIO_PAINEL" ]; then step "Conferindo o DNS do painel"; aguardar_dns "$DOMINIO_PAINEL" "$IP"; fi
    exigir_portas_livres
    if [ -n "$DOMINIO_PAINEL" ]; then
      info "testando se $DOMINIO_PAINEL chega a este servidor pela porta 80"
      if ! testar_porta80 "$DOMINIO_PAINEL"; then
        warn "não consegui abrir http://$DOMINIO_PAINEL daqui. Porta 80 ocupada ou domínio apontando para outro IP: o certificado HTTPS do painel não será emitido."
        confirmar_continuar
      fi
    fi
    step "Instalando o Coolify $COOLIFY_VERSION (instala o Docker junto; leva alguns minutos)"
    instalar_coolify
    ajustar_porta_ssh
    if [ -n "$DOMINIO_PAINEL" ]; then step "Configurando o domínio do painel"; if painel_dominio "$DOMINIO_PAINEL"; then PAINEL_OK=1; fi; fi
  fi

  fazer_perguntas
  checar_db_externo

  step "Conferindo o DNS"
  aguardar_dns "$DOMINIO" "$IP"

  step "Liberando o acesso ao código"
  gerar_e_registrar_chave

  step "Criando o WhatsBot Pro no Coolify"
  abrir_api
  criar_pro

  step "Criando o administrador"
  criar_admin
  gravar_acesso

  step "Esperando o certificado HTTPS"
  if aguardar_cert "$DOMINIO"; then
    info "certificado emitido para $DOMINIO"
    if curl -fsS -m 15 "https://$DOMINIO/health" >/dev/null 2>&1; then info "https://$DOMINIO/health respondeu"
    else warn "o certificado saiu, mas https://$DOMINIO/health ainda não respondeu; pode levar mais alguns segundos."; fi
  else
    warn "o certificado de $DOMINIO não saiu. Veja o motivo:  docker logs coolify-proxy 2>&1 | grep -iE 'acme|certificate' | tail -20"
    warn "depois de corrigir o DNS ou o firewall:  docker restart coolify-proxy"
  fi
  if [ "$PAINEL_OK" = 1 ] && aguardar_cert "$DOMINIO_PAINEL"; then info "certificado emitido para $DOMINIO_PAINEL"; fi

  local url_painel="http://$IP:8000"
  if [ "$PAINEL_OK" = 1 ]; then url_painel="https://$DOMINIO_PAINEL"; fi

  printf '\n\033[1;32mTudo no ar!\033[0m\n\n'
  echo "  WhatsBot Pro:  https://$DOMINIO"
  echo "  Login:         $EMAIL"
  if [ "$ADMIN_APLICADO" != 1 ]; then echo "  Senha:         a do administrador que já existia"
  elif [ "$SENHA_GERADA" = 1 ]; then echo "  Senha:         $SENHA"
  else echo "  Senha:         a que você digitou"; fi
  echo "  Coolify:       $url_painel"
  [ "$COOLIFY_NOVO" != 1 ] || echo "  Login do Coolify: $COOLIFY_EMAIL (senha em /root/coolify-acesso.txt)"
  echo "  Estes dados: $ACESSO (só o root lê)"
  echo "  Chave do código: $KEY (guarde uma cópia)"
  echo "  Repositório:     $REPO"
  cat <<EOF

  Firewall: deixe abertas as portas 80 e 443.
  Para atualizar: Coolify > $PROJETO > $NOME > Redeploy (3 a 8 minutos).
  Para ver o código-fonte ou pedir ajuda, fale com a Techify${CONTATO:+: $CONTATO}.
EOF
  if [ "$COOLIFY_NOVO" = 1 ]; then
    if [ "$PAINEL_OK" = 1 ]; then
      echo "  O painel do Coolify já está em HTTPS: feche as portas 8000, 6001 e 6002 no firewall do provedor"
      echo "  (o firewall do próprio servidor, ufw, não fecha portas publicadas pelo Docker)."
    else
      echo "  O painel do Coolify está em http://${IP}:8000 (sem HTTPS): use só em rede de confiança e feche a porta 8000 depois."
    fi
    echo "  Guarde a linha APP_KEY= de /data/coolify/source/.env (a chave do Coolify)."
  fi
}

main "$@"
