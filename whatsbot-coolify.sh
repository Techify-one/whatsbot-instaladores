#!/usr/bin/env bash
# =====================================================================
#  WhatsBot-Lite no Coolify — instalação completa com domínio e HTTPS
#  Ubuntu ou Debian limpo, como root.
#
#    bash <(curl -fsSL https://scripts.techify.site/whatsbot-coolify)
#    bash <(wget -qO- https://scripts.techify.site/whatsbot-coolify)   # sem curl
#
#  Antes: aponte o domínio (registro A) para o IP público deste servidor
#  e deixe as portas 80 e 443 abertas no firewall.
#
#  Sem perguntas (automação), defina as variáveis antes do comando:
#    DOMINIO=bot.exemplo.com  EMAIL=voce@gmail.com  SENHA='...'
#    [DOMINIO_PAINEL=coolify.exemplo.com]  [USUARIO=admin]  [FORCAR=1]
#  Pode rodar de novo: atualiza o WhatsBot e preserva os dados.
# =====================================================================
set -Eeuo pipefail

REPO="${REPO:-https://github.com/Techify-one/whatsbot-lite}"
BRANCH="${BRANCH:-main}"
# Versão do Coolify validada com este script (o deploy usa a API dele, que pode mudar entre versões).
COOLIFY_VERSION="${COOLIFY_VERSION:-4.7.5}"
DNS_TIMEOUT="${DNS_TIMEOUT:-1800}"   # segundos esperando o DNS apontar para este servidor

DOMINIO="${DOMINIO:-}"
DOMINIO_PAINEL="${DOMINIO_PAINEL:-}"
EMAIL="${EMAIL:-}"
SENHA="${SENHA:-}"
USUARIO="${USUARIO:-admin}"
FORCAR="${FORCAR:-0}"   # 1 = segue sem perguntar quando algo foge do recomendado

TOKEN_NAME=whatsbot-provision
APT="apt-get -o DPkg::Lock::Timeout=300"
REGEX_DOMINIO='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}$'

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mAviso:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

have_tty()  { { : </dev/tty; } 2>/dev/null; }
port_busy() { ss -ltn "( sport = :$1 )" 2>/dev/null | awk 'NR>1' | grep -q .; }
local_ip()  { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }
psql_c()    { docker exec -i coolify-db psql -q -U coolify -d coolify -v ON_ERROR_STOP=1 -tA "$@"; }

# DNS pelo resolvedor público (1.1.1.1), sem cache local: é o que o Let's Encrypt enxerga.
# doh NOME TIPO_NUMERICO  (A=1, MX=15, AAAA=28)
doh() {
  curl -fsS -m 10 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=$1&type=$2" 2>/dev/null \
    | jq -r --argjson t "$2" '.Answer[]? | select(.type==$t) | .data' 2>/dev/null || true
}

confirmar_continuar() {
  if [ "$FORCAR" = 1 ]; then return 0; fi
  if ! have_tty; then warn "sem terminal para perguntar; seguindo mesmo assim."; return 0; fi
  local r=""
  read -r -p "    Continuar mesmo assim? [s/N] " r </dev/tty
  case "$r" in s|S|sim|SIM|y|Y) return 0 ;; *) die "instalação cancelada." ;; esac
}

# ---------------------------------------------------------------- verificações

verificar_sistema() {
  . /etc/os-release
  local id=${ID:-?} ver=${VERSION_ID:-} nome=${PRETTY_NAME:-desconhecido} aviso=""
  case "$id" in
    ubuntu)
      case "$ver" in
        22.04|24.04|26.04|26.10) ;;
        *)
          if   dpkg --compare-versions "$ver" lt 22.04; then aviso="mais antigo que o mínimo (Ubuntu 22.04); o Docker não suporta mais esta versão."
          elif dpkg --compare-versions "$ver" gt 26.10; then aviso="mais novo que as versões listadas pelo Docker (até 26.10); provavelmente funciona."
          else aviso="versão intermediária, sem suporte do Docker. O instalador tenta contornar, mas prefira uma LTS."
          fi ;;
      esac ;;
    debian)
      case "$ver" in
        12|13) ;;
        "") aviso="versão de testes (testing/sid), sem número fixo." ;;
        *)
          if dpkg --compare-versions "$ver" lt 12; then aviso="mais antigo que o mínimo (Debian 12); o Docker não suporta mais esta versão."
          else aviso="mais novo que as versões listadas pelo Docker (até Debian 13); provavelmente funciona."
          fi ;;
      esac ;;
    *) aviso="só Ubuntu e Debian foram testados." ;;
  esac
  if [ -n "$aviso" ]; then
    warn "$nome: $aviso"
    info "Recomendado: Ubuntu 22.04, 24.04 ou 26.04 (LTS), ou Debian 12 ou 13."
    confirmar_continuar
  else
    info "Sistema: $nome (ok)"
  fi
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) warn "arquitetura $(uname -m): só x86_64 e arm64 têm o motor do WhatsApp (GOWA) pronto."; confirmar_continuar ;;
  esac
}

verificar_recursos() {
  local mem disk cpu
  mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  disk=$(df -Pm / | awk 'NR==2{print $4}')
  cpu=$(nproc)
  if [ "$cpu" -lt 2 ];     then warn "só $cpu CPU; o recomendado são 2 ou mais."; fi
  if [ "$mem" -lt 1800 ];  then warn "só ${mem} MB de RAM; o recomendado são 2048 MB ou mais (a construção da imagem pode falhar)."; fi
  if [ "$disk" -lt 20000 ]; then warn "só ${disk} MB livres em /; o recomendado são 30 GB ou mais."; fi
  if [ ! -d /run/systemd/system ]; then warn "este servidor não usa systemd; o Docker pode não subir sozinho no boot."; fi
  return 0
}

apt_preparar() {
  export DEBIAN_FRONTEND=noninteractive
  local out f
  out=$($APT update 2>&1) || true
  # Ubuntu intermediário (ex.: 24.10) sai de suporte e some do archive.ubuntu.com (apt dá 404).
  if grep -qE "(no longer has|does not have) a Release file|404 +Not Found" <<<"$out"; then
    warn "esta versão do Ubuntu saiu de suporte; usando o arquivo old-releases.ubuntu.com."
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
      if [ -f "$f" ]; then
        sed -i -E 's#https?://(archive|security|[a-z]{2}\.archive)\.ubuntu\.com/ubuntu#http://old-releases.ubuntu.com/ubuntu#g' "$f"
      fi
    done
  fi
  $APT update -qq >/dev/null
  $APT install -y -qq ca-certificates curl wget git jq openssl iproute2 python3 >/dev/null
}

# ---------------------------------------------------------------- perguntas

valid_password() {
  [[ ${#1} -ge 8 && $1 =~ [A-Z] && $1 =~ [a-z] && $1 =~ [0-9] && $1 =~ [^A-Za-z0-9] ]]
}

# O Coolify só cria o administrador se o e-mail tiver domínio com DNS (MX ou A).
email_ok() {
  [[ "$1" =~ ^[^@\ ]+@[^@\ ]+\.[^@\ ]+$ ]] || return 1
  # Se o DNS-over-HTTPS estiver bloqueado aqui, não dá para checar: aceita pelo formato.
  [ -n "$(doh cloudflare.com 1)" ] || return 0
  local d=${1#*@}
  [ -n "$(doh "$d" 15)" ] || [ -n "$(doh "$d" 1)" ]
}

# perguntar VAR "texto" validador "mensagem de erro" [secret]
perguntar() {
  local var=$1 prompt=$2 check=$3 err=$4 secret=${5:-} val=""
  if [ -n "${!var:-}" ]; then
    "$check" "${!var}" || die "$err"
    return 0
  fi
  if ! have_tty; then
    # Sem terminal: campo opcional (aceita vazio) segue vazio; obrigatório exige a variável.
    if "$check" ""; then return 0; fi
    die "sem terminal para perguntar. Defina $var antes do comando."
  fi
  while :; do
    if [ -n "$secret" ]; then read -r -s -p "$prompt" val </dev/tty; echo >&2
    else read -r -p "$prompt" val </dev/tty; fi
    if "$check" "$val"; then printf -v "$var" '%s' "$val"; return 0; fi
    printf '    %s\n' "$err" >&2
  done
}

ck_dominio()  { [[ "$1" =~ $REGEX_DOMINIO ]]; }
ck_dom_opc()  { [ -z "$1" ] || [[ "$1" =~ $REGEX_DOMINIO ]]; }
ck_senha()    { [ -z "$1" ] || valid_password "$1"; }

fazer_perguntas() {
  printf '\n\033[1;32m  WhatsBot-Lite no Coolify\033[0m\n'
  printf '  Responda 4 perguntas. O domínio precisa já apontar para este servidor.\n\n'

  perguntar DOMINIO "  1) Domínio do WhatsBot (ex.: bot.seudominio.com): " ck_dominio \
    "domínio inválido. Use só o nome, sem http:// e sem barra (ex.: bot.seudominio.com)."
  perguntar DOMINIO_PAINEL "  2) Domínio do painel do Coolify (opcional; Enter = acessar por IP:8000): " ck_dom_opc \
    "domínio inválido. Use só o nome (ex.: coolify.seudominio.com) ou deixe vazio."
  if [ -n "$DOMINIO_PAINEL" ] && [ "$DOMINIO_PAINEL" = "$DOMINIO" ]; then
    die "o domínio do WhatsBot e o do painel precisam ser diferentes."
  fi
  perguntar EMAIL "  3) E-mail do administrador do Coolify (precisa ser real, ex.: voce@gmail.com): " email_ok \
    "e-mail inválido, ou o domínio dele não existe no DNS (o Coolify recusaria o cadastro)."

  SENHA_GERADA=0
  if [ -z "$SENHA" ]; then
    local s1="" s2=""
    if have_tty; then
      while :; do
        read -r -s -p "  4) Senha do Coolify (8+ caracteres com maiúscula, minúscula, número e símbolo; Enter = gerar): " s1 </dev/tty; echo >&2
        if [ -z "$s1" ]; then break; fi
        if ! valid_password "$s1"; then printf '    senha fraca: faltou maiúscula, minúscula, número ou símbolo, ou tem menos de 8 caracteres.\n' >&2; continue; fi
        read -r -s -p "     Repita a senha: " s2 </dev/tty; echo >&2
        if [ "$s1" = "$s2" ]; then break; fi
        printf '    as senhas não conferem.\n' >&2
      done
    fi
    SENHA=$s1
  fi
  if [ -z "$SENHA" ]; then
    SENHA="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-14)Aa1!"
    SENHA_GERADA=1
  fi
  valid_password "$SENHA" || die "a senha precisa de 8+ caracteres com maiúscula, minúscula, número e símbolo. Sem isso o Coolify descarta o usuário em silêncio e deixa o cadastro aberto."
  [[ "$USUARIO" =~ ^[A-Za-z0-9_\ -]{3,}$ ]] || die "USUARIO precisa ter 3+ caracteres (letras, números, espaço, - ou _)."
}

# ---------------------------------------------------------------- DNS e alcance

# Espera o domínio apontar para este servidor; tenta de novo a cada 10 s até DNS_TIMEOUT.
aguardar_dns() {  # $1 = domínio  $2 = IP público deste servidor
  local d=$1 ip=$2 t0=$SECONDS got last="" msg
  info "conferindo $d"
  while :; do
    got=$(doh "$d" 1 | awk 'NR==1')
    if [ "$got" = "$ip" ]; then
      info "DNS ok: $d -> $ip"
      local aaaa; aaaa=$(doh "$d" 28 | awk 'NR==1')
      if [ -n "$aaaa" ]; then
        warn "$d também tem um registro AAAA (IPv6: $aaaa). O Let's Encrypt prefere IPv6; se este servidor não responde nele, o certificado falha. Remova o AAAA se der erro."
      fi
      return 0
    fi
    if [ -z "$got" ]; then msg="$d ainda não existe no DNS. Crie um registro A para $ip."
    else msg="$d aponta para $got, mas este servidor é $ip. Se usa Cloudflare, deixe o registro como \"Somente DNS\" (nuvem cinza)."
    fi
    if [ "$msg" != "$last" ]; then printf '    %s\n    aguardando... (Ctrl+C cancela; depois de corrigir é só esperar, ele tenta sozinho)\n' "$msg"; last=$msg; fi
    if [ $((SECONDS - t0)) -ge "$DNS_TIMEOUT" ]; then
      die "o DNS de $d não apontou para $ip em $((DNS_TIMEOUT / 60)) minutos. Corrija o registro e rode o comando de novo."
    fi
    sleep 10
  done
}

# Sobe um servidor temporário na porta 80 e pede um arquivo secreto pelo próprio domínio:
# prova que o nome chega neste servidor, que é exatamente o que o Let's Encrypt fará.
testar_porta80() {  # $1 = domínio
  local d=$1 dir tok pid ok=1 i
  dir=$(mktemp -d); tok=$(openssl rand -hex 8); echo "ok-$tok" > "$dir/$tok"
  (cd "$dir" && exec python3 -m http.server 80 --bind 0.0.0.0 >/dev/null 2>&1) &
  pid=$!
  sleep 1
  for i in 1 2 3 4 5 6; do
    if [ "$(curl -fsS -m 8 "http://$d/$tok" 2>/dev/null || true)" = "ok-$tok" ]; then ok=0; break; fi
    sleep 5
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$dir"
  return $ok
}

# ---------------------------------------------------------------- Coolify

api_cleanup() {
  psql_c -c "DELETE FROM personal_access_tokens WHERE name = '$TOKEN_NAME'" >/dev/null 2>&1 || true
  psql_c -c "UPDATE instance_settings SET is_api_enabled = false WHERE id = 0" >/dev/null 2>&1 || true
}

instalar_coolify() {
  # O install.sh usa $USER para nomear a chave SSH do "localhost".
  export USER=root
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o "$tmp/install.sh"
  ROOT_USERNAME="$USUARIO" ROOT_USER_EMAIL="$EMAIL" ROOT_USER_PASSWORD="$SENHA" AUTOUPDATE=false \
    bash "$tmp/install.sh" "$COOLIFY_VERSION"
  rm -rf "$tmp"

  step "Esperando o Coolify responder"
  local i ok=0
  for i in $(seq 1 90); do
    if curl -fsS -m 5 http://127.0.0.1:8000/api/health >/dev/null 2>&1; then ok=1; break; fi
    sleep 4
  done
  if [ "$ok" != 1 ]; then docker ps -a; die "o Coolify não respondeu em /api/health após 6 minutos."; fi
  for i in $(seq 1 60); do
    if [ "$(psql_c -c 'select count(*) from users where id = 0' 2>/dev/null || true)" = 1 ]; then break; fi
    sleep 2
  done
  [ "$(psql_c -c 'select count(*) from users where id = 0')" = 1 ] \
    || die "o usuário administrador não foi criado (senha recusada ou e-mail sem domínio real). Veja: docker logs coolify | grep -A3 'Invalid Root User'"
}

# Define o domínio do painel do próprio Coolify (Configurações > Domínio da instância), sem a interface.
painel_dominio() {  # $1 = domínio
  local d=$1 out
  # Captura a saída antes do grep: com pipefail, "grep -q" fechando cedo pode dar falso negativo.
  out=$(docker exec -u www-data -e DASH_FQDN="https://$d" coolify php artisan tinker --execute='
$s = instanceSettings();
$s->fqdn = getenv("DASH_FQDN");
$s->save();
\App\Models\Server::findOrFail(0)->setupDynamicProxyConfiguration();
echo "DASH_OK ".instanceSettings()->fqdn.PHP_EOL;' 2>&1 || true)
  if grep -q "DASH_OK https://$d" <<<"$out"; then
    info "painel configurado em https://$d"
  else
    warn "não consegui configurar o domínio do painel; ele continua em http://$IP:8000."
    printf '%s\n' "$out" | tail -5 >&2
    return 1
  fi
}

# Espera o Traefik trazer o certificado do Let's Encrypt para o domínio.
aguardar_cert() {  # $1 = domínio
  local i iss
  for i in $(seq 1 36); do
    iss=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$1" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)
    if [[ "$iss" == *"Let's Encrypt"* ]]; then return 0; fi
    sleep 5
  done
  return 1
}

criar_whatsbot() {
  local api=http://127.0.0.1:8000/api/v1 app_name=whatsbot-lite project_name=WhatsBot
  local token server project app d s i have v fqdn="https://$DOMINIO"

  token=$(openssl rand -hex 24)
  trap api_cleanup EXIT
  psql_c <<SQL
UPDATE instance_settings SET is_api_enabled = true WHERE id = 0;
UPDATE teams SET show_boarding = false WHERE id = 0;
DELETE FROM personal_access_tokens WHERE name = '$TOKEN_NAME';
INSERT INTO personal_access_tokens (tokenable_type, tokenable_id, name, token, team_id, abilities, created_at, updated_at)
VALUES ('App\Models\User', 0, '$TOKEN_NAME', encode(sha256(convert_to('$token', 'UTF8')), 'hex'), '0', '["root"]', now(), now());
SQL

  capi() {  # capi METHOD PATH [JSON]
    local m=$1 p=$2 body=${3:-}
    curl --fail-with-body -sS -X "$m" -H "Authorization: Bearer $token" -H 'Accept: application/json' \
      ${body:+-H 'Content-Type: application/json' -d "$body"} "$api$p"
  }

  server=$(capi GET /servers | jq -r 'first(.[] | select(.name == "localhost") | .uuid) // empty')
  [ -n "$server" ] || die "servidor localhost não encontrado no Coolify."

  info "esperando o proxy (Traefik)"
  for i in $(seq 1 90); do
    if [ "$(capi GET "/servers/$server/proxy" | jq -r .status)" = running ]; then break; fi
    sleep 2
  done

  project=$(capi GET /projects | jq -r --arg n "$project_name" 'first(.[] | select(.name == $n) | .uuid) // empty')
  [ -n "$project" ] || project=$(capi POST /projects "$(jq -nc --arg n "$project_name" '{name: $n}')" | jq -r .uuid)

  app=$(capi GET /applications | jq -r --arg n "$app_name" 'first(.[] | select(.name == $n) | .uuid) // empty')
  if [ -z "$app" ]; then
    app=$(capi POST /applications/public "$(jq -nc \
      --arg p "$project" --arg s "$server" --arg r "$REPO" --arg b "$BRANCH" --arg n "$app_name" --arg d "$fqdn" \
      '{project_uuid: $p, server_uuid: $s, environment_name: "production", git_repository: $r, git_branch: $b,
        build_pack: "dockerfile", ports_exposes: "8080", name: $n, domains: $d,
        health_check_enabled: false, instant_deploy: false}')" | jq -r .uuid)
  else
    capi PATCH "/applications/$app" "$(jq -nc --arg d "$fqdn" '{domains: $d}')" >/dev/null
  fi

  # Os VOLUME do Dockerfile são anônimos: sem volumes nomeados, cada redeploy começaria com
  # /app/storages vazio (banco e sessão do WhatsApp).
  have=$(capi GET "/applications/$app/storages" | jq -r '.persistent_storages[].mount_path')
  for v in storages statics logs; do
    if ! grep -qx "/app/$v" <<<"$have"; then
      capi POST "/applications/$app/storages" \
        "$(jq -nc --arg n "$v" --arg m "/app/$v" '{type: "persistent", name: $n, mount_path: $m}')" >/dev/null
    fi
  done

  step "Construindo e publicando o WhatsBot (3 a 8 minutos)"
  d=$(capi POST "/deploy?uuid=$app" '{}' | jq -r '.deployments[0].deployment_uuid')
  [ -n "$d" ] && [ "$d" != null ] || die "o deploy não entrou na fila."
  s=""
  for i in $(seq 1 240); do
    s=$(capi GET "/deployments/$d" | jq -r .status)
    case $s in
      finished) break ;;
      failed|cancelled-by-user) die "o deploy terminou como '$s'. Veja no painel do Coolify: WhatsBot > $app_name > Deployments." ;;
    esac
    sleep 5
  done
  [ "$s" = finished ] || die "tempo esgotado esperando o deploy (último estado: $s)."
}

main() {
  [ "$(id -u)" -eq 0 ] || die "rode como root (use: sudo -i)"

  step "Verificando o servidor"
  verificar_sistema
  verificar_recursos
  step "Preparando o servidor"
  apt_preparar   # antes das portas: num Debian limpo o "ss" (iproute2) ainda não existe

  JA_INSTALADO=0
  local lista; lista=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
  if grep -qx coolify <<<"$lista"; then JA_INSTALADO=1; fi
  if [ "$JA_INSTALADO" = 0 ]; then
    local p
    for p in 80 443 8000; do
      if port_busy "$p"; then die "a porta $p já está em uso neste servidor (o Coolify precisa de 80, 443 e 8000 livres)."; fi
    done
  fi
  IP=$(curl -4fsS -m 8 https://ifconfig.io 2>/dev/null || true)
  if [ -z "$IP" ]; then IP=$(local_ip); fi
  [ -n "$IP" ] || die "não consegui descobrir o IP deste servidor."
  info "IP público deste servidor: $IP"

  fazer_perguntas

  step "Conferindo o DNS"
  aguardar_dns "$DOMINIO" "$IP"
  if [ -n "$DOMINIO_PAINEL" ]; then aguardar_dns "$DOMINIO_PAINEL" "$IP"; fi

  if [ "$JA_INSTALADO" = 0 ]; then
    info "testando se $DOMINIO chega a este servidor pela porta 80"
    if testar_porta80 "$DOMINIO"; then
      # O teste parte de dentro do servidor: prova o nome e a porta, não o firewall do provedor.
      info "porta 80 responde pelo domínio (o firewall externo só é provado quando o certificado sair)"
    else
      warn "não consegui abrir http://$DOMINIO daqui mesmo. Causas comuns: a porta 80 ocupada, ou o domínio apontando para outro IP. O certificado HTTPS não será emitido assim."
      confirmar_continuar
    fi
  fi

  info "o Let's Encrypt aceita só 5 certificados por semana para o mesmo nome; evite refazer a instalação do zero muitas vezes com o mesmo domínio."

  if [ "$JA_INSTALADO" = 1 ]; then
    step "Coolify já instalado: atualizando"
  else
    step "Instalando o Coolify $COOLIFY_VERSION (instala o Docker junto; leva alguns minutos)"
  fi
  instalar_coolify

  # Domínio do painel antes dos apps: se o DNS ou o certificado falhar, aparece cedo.
  PAINEL_OK=0
  if [ -n "$DOMINIO_PAINEL" ]; then
    step "Configurando o domínio do painel"
    if painel_dominio "$DOMINIO_PAINEL"; then PAINEL_OK=1; fi
  fi

  step "Criando o WhatsBot no Coolify"
  criar_whatsbot

  step "Esperando o certificado HTTPS"
  local app_cert=0 painel_cert=0
  if aguardar_cert "$DOMINIO"; then app_cert=1; info "certificado emitido para $DOMINIO"; fi
  if [ "$PAINEL_OK" = 1 ] && aguardar_cert "$DOMINIO_PAINEL"; then painel_cert=1; info "certificado emitido para $DOMINIO_PAINEL"; fi
  if [ "$app_cert" = 1 ]; then
    if curl -fsS -m 15 "https://$DOMINIO/health" >/dev/null 2>&1; then info "https://$DOMINIO/health respondeu"
    else warn "o certificado saiu, mas https://$DOMINIO/health ainda não respondeu; o WhatsBot pode levar mais alguns segundos."; fi
  fi
  if [ "$app_cert" = 0 ]; then
    warn "o certificado de $DOMINIO não saiu. Veja o motivo:  docker logs coolify-proxy 2>&1 | grep -iE 'acme|certificate' | tail -20"
    warn "depois de corrigir o DNS ou o firewall:  docker restart coolify-proxy"
  fi

  local url_app="https://$DOMINIO" url_painel="http://$IP:8000" acesso=/root/whatsbot-acesso.txt
  if [ "$PAINEL_OK" = 1 ]; then url_painel="https://$DOMINIO_PAINEL"; fi

  umask 077
  {
    echo "WhatsBot:  $url_app"
    echo "Coolify:   $url_painel   (também em http://$IP:8000)"
    echo "E-mail:    $EMAIL"
    if [ "$JA_INSTALADO" = 1 ]; then echo "Senha:     a mesma de antes (o Coolify já estava instalado)"
    else echo "Senha:     $SENHA"; fi
  } > "$acesso"

  printf '\n\033[1;32mTudo no ar!\033[0m\n\n'
  sed 's/^/  /' "$acesso"
  if [ "$SENHA_GERADA" = 1 ] && [ "$JA_INSTALADO" = 0 ]; then printf '\n  A senha foi gerada agora. Estes dados também estão em %s (só o root lê).\n' "$acesso"; fi
  cat <<EOF

  Portas a deixar abertas no firewall: 80 e 443 (WhatsBot e HTTPS).
  Se o painel do Coolify está em domínio, as portas 8000, 6001 e 6002 podem ser fechadas.
  Guarde /data/coolify/source/.env (tem a chave APP_KEY do Coolify).
  Atenção: o painel do WhatsBot não tem senha; qualquer pessoa com o endereço entra.

EOF
}

main "$@"
