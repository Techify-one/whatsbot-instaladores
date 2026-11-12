#!/usr/bin/env bash
# =====================================================================
#  WhatsBot-Lite — instalação com Docker
#  Ubuntu ou Debian, como root. Sem perguntas.
#
#    bash <(curl -fsSL https://scripts.techify.site/whatsbot-docker)
#    bash <(wget -qO- https://scripts.techify.site/whatsbot-docker)    # sem curl
#
#  Já tem Docker? Ele é reaproveitado: nada é reinstalado nem alterado, o script
#  só baixa o WhatsBot e sobe o container dele (não mexe nos seus outros containers).
#
#  Opcional (antes do comando):
#    WHATSBOT_PORTA=8081   porta publicada (padrão: 8080, ou a próxima livre)
#    WHATSBOT_FORCAR=1     segue sem perguntar quando o sistema foge do recomendado
#    WHATSBOT_DIR=/opt/whatsbot   WHATSBOT_REPO=...   WHATSBOT_BRANCH=main
#  Pode rodar de novo: atualiza o WhatsBot e preserva os dados.
# =====================================================================
set -Eeuo pipefail
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"   # "su" sem o traço não traz o sbin (useradd, runuser, ss)

REPO="${WHATSBOT_REPO:-https://github.com/Techify-one/whatsbot-lite}"
BRANCH="${WHATSBOT_BRANCH:-main}"
DIR="${WHATSBOT_DIR:-/opt/whatsbot}"
PORTA="${WHATSBOT_PORTA:-}"
FORCAR="${WHATSBOT_FORCAR:-0}"
MARCA_OVERRIDE="# gerado por whatsbot-docker (apague esta linha se quiser editar o arquivo sem que o instalador o refaça)"
APT="apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
IP4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
APT_OUT=""

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mAviso:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

have_tty()   { { : </dev/tty; } 2>/dev/null; }
port_busy()  { ss -ltn "( sport = :$1 )" 2>/dev/null | awk 'NR>1' | grep -q .; }
local_ip()   { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true; }
public_ip()  { local p; p=$(curl -4fsS -m 6 https://ifconfig.io 2>/dev/null || true); if [[ "$p" =~ $IP4_RE ]]; then printf '%s' "$p"; fi; }
ip_privado() { [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|127\.) ]]; }
http_ok()    {
  if command -v curl >/dev/null 2>&1; then curl -fsI -m 15 "$1" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then wget -q --spider -T 15 "$1"
  else return 0; fi
}

confirmar_continuar() {
  if [ "$FORCAR" = 1 ]; then return 0; fi
  if ! have_tty; then warn "sem terminal para perguntar; seguindo mesmo assim."; return 0; fi
  local r=""
  read -r -p "    Continuar mesmo assim? [s/N] " r </dev/tty
  case "$r" in s|S|sim|SIM|y|Y) return 0 ;; *) die "instalação cancelada." ;; esac
}

validar_entradas() {
  [[ "$DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]            || die "WHATSBOT_DIR inválido: use um caminho absoluto simples (ex.: /opt/whatsbot)."
  [[ "$BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "WHATSBOT_BRANCH inválido."
  [[ "$REPO" =~ ^(https://|git@)[A-Za-z0-9._:/@-]+$ ]] || die "WHATSBOT_REPO inválido (use um endereço https://...)."
  if [ -n "$PORTA" ]; then
    [[ "$PORTA" =~ ^[0-9]+$ ]] && [ "$PORTA" -ge 1 ] && [ "$PORTA" -le 65535 ] || die "WHATSBOT_PORTA inválida: $PORTA"
  fi
  return 0
}

# ---------------------------------------------------------------- verificações

verificar_sistema() {
  local id=${ID:-?} ver=${VERSION_ID:-} nome=${PRETTY_NAME:-desconhecido} aviso=""
  case "$id" in
    ubuntu)
      case "$ver" in
        22.04|24.04|26.04|26.10) ;;   # as versões que a documentação do Docker lista
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
}

verificar_arquitetura() {
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) warn "arquitetura $(uname -m): só x86_64 e arm64 têm o motor do WhatsApp (GOWA) pronto."; confirmar_continuar ;;
  esac
}

verificar_recursos() {
  local mem disk
  mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  disk=$(df -Pm / | awk 'NR==2{print $4}')
  if [ "$mem" -lt 1800 ];  then warn "só ${mem} MB de RAM; o recomendado são 2048 MB ou mais (a construção da imagem pode falhar)."; fi
  if [ "$disk" -lt 8000 ]; then warn "só ${disk} MB livres em /; o recomendado são 10 GB ou mais."; fi
  return 0
}

# ---------------------------------------------------------------- apt (só quando precisa)

# Espera outro apt terminar (cloud-init, atualização automática logo após criar a VPS).
apt_update() {
  local i
  for i in $(seq 1 30); do
    if APT_OUT=$($APT update 2>&1); then return 0; fi
    if grep -qiE "Could not get lock|Unable to acquire the dpkg|is another process using it" <<<"$APT_OUT"; then
      if [ "$i" = 1 ]; then info "outro processo está usando o apt (atualização automática?); aguardando..."; fi
      sleep 10
    else
      return 1
    fi
  done
  return 1
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
  if apt_update; then return 0; fi
  if corrigir_apt_ubuntu_antigo && apt_update; then return 0; fi
  restaurar_apt
  printf '%s\n' "$APT_OUT" | tail -6 >&2
  die "o apt não conseguiu atualizar a lista de pacotes (veja acima)."
}

garantir_ferramentas() {
  local c faltam=0
  for c in curl git ss ip; do
    if ! command -v "$c" >/dev/null 2>&1; then faltam=1; fi
  done
  if [ "$faltam" = 0 ]; then info "ferramentas básicas já instaladas"; return 0; fi
  apt_preparar
  $APT install -y -qq ca-certificates curl git iproute2 >/dev/null
}

# ---------------------------------------------------------------- Docker

instalar_docker_novo() {
  local i
  for i in 1 2 3; do
    if curl -fsSL https://get.docker.com | sh; then return 0; fi
    warn "a instalação do Docker falhou (tentativa $i de 3); tentando de novo em 20 s."
    sleep 20
  done
  return 1
}

garantir_compose() {
  if docker compose version >/dev/null 2>&1; then return 0; fi
  info "o Docker não tem o plugin 'docker compose'; tentando instalar..."
  apt_preparar
  if ! $APT install -y -qq docker-compose-plugin >/dev/null 2>&1; then
    $APT install -y -qq docker-compose-v2 >/dev/null 2>&1 || true
  fi
  docker compose version >/dev/null 2>&1 \
    || die "o Docker está instalado, mas sem o plugin 'docker compose'. Instale (apt install docker-compose-plugin, ou docker-compose-v2 no Ubuntu) e rode de novo."
}

garantir_docker() {
  local i out virt
  if command -v docker >/dev/null 2>&1; then
    if ! docker info >/dev/null 2>&1; then
      info "o Docker está instalado, mas parado; iniciando..."
      systemctl start docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
      for i in 1 2 3 4 5 6 7 8 9 10; do docker info >/dev/null 2>&1 && break; sleep 2; done
    fi
    docker info >/dev/null 2>&1 || die "o Docker está instalado, mas não responde (docker info). Veja: systemctl status docker"
    garantir_compose
    info "Docker já instalado, reaproveitando: $(docker --version)"
    return 0
  fi
  apt_preparar
  instalar_docker_novo || die "não consegui instalar o Docker."
  systemctl enable --now docker >/dev/null 2>&1 || true
  if ! out=$(docker run --rm hello-world 2>&1); then
    printf '%s\n' "$out" | tail -8 >&2
    virt=$(systemd-detect-virt 2>/dev/null || true)
    if [ "$virt" = lxc ]; then
      die "o Docker não consegue rodar containers neste LXC. No Proxmox: Options > Features > marque 'Nesting' (no host: pct set <ID> --features nesting=1), reinicie o container e rode de novo."
    fi
    die "o Docker foi instalado, mas não conseguiu rodar um container de teste (veja o erro acima; pode ser rede, o limite de downloads do Docker Hub ou o serviço parado)."
  fi
  info "Docker instalado e funcionando: $(docker --version)"
}

# ---------------------------------------------------------------- porta e container

escolher_porta() {
  local atual="" dono=""
  if docker inspect whatsbot >/dev/null 2>&1; then
    dono=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' whatsbot 2>/dev/null || true)
    [ "$dono" = "$DIR" ] || die "já existe um container chamado 'whatsbot' que não é desta instalação (pasta: ${dono:-desconhecida}). Renomeie ou remova esse container e rode de novo."
    atual=$(docker port whatsbot 8080/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' || true)
  fi
  # Reexecução: mantém a porta, a menos que peçam outra.
  if [ -n "$atual" ] && { [ -z "$PORTA" ] || [ "$PORTA" = "$atual" ]; }; then PORTA=$atual; return 0; fi
  if [ -n "$PORTA" ]; then
    if port_busy "$PORTA" && [ "$PORTA" != "$atual" ]; then die "a porta $PORTA já está em uso neste servidor. Escolha outra: WHATSBOT_PORTA=8081"; fi
    return 0
  fi
  local p=8080
  while port_busy "$p"; do
    p=$((p + 1))
    if [ "$p" -gt 8099 ]; then die "não achei porta livre entre 8080 e 8099. Use WHATSBOT_PORTA=<número livre>."; fi
  done
  if [ "$p" != 8080 ]; then info "a porta 8080 está ocupada; usando a $p."; fi
  PORTA=$p
}

preparar_codigo() {
  if [ -d "$DIR/.git" ]; then
    local origem; origem=$(git -C "$DIR" remote get-url origin 2>/dev/null || true)
    [ "$origem" = "$REPO" ] || die "$DIR é um clone de outro repositório ($origem), não de $REPO."
    git -C "$DIR" pull --ff-only
  else
    if [ -e "$DIR" ] && [ -n "$(ls -A "$DIR")" ]; then die "$DIR existe e não é um clone do WhatsBot."; fi
    git clone --depth 1 --branch "$BRANCH" -- "$REPO" "$DIR"
  fi
}

escrever_override() {
  # O compose do repo só tem "expose" (feito para proxy/Coolify); para acessar por IP:porta publicamos a
  # porta num override. Se a pessoa editou o arquivo (sem a marca), é respeitado e não é reescrito.
  if [ ! -f docker-compose.override.yaml ] || grep -qF "$MARCA_OVERRIDE" docker-compose.override.yaml; then
    cat > docker-compose.override.yaml <<EOF
$MARCA_OVERRIDE
services:
  whatsbot:
    ports:
      - "${PORTA}:8080"
EOF
  else
    info "mantendo o seu docker-compose.override.yaml (editado por você)."
  fi
}

main() {
  [ "$(id -u)" -eq 0 ] || die "rode como root (use: sudo -i)"
  # shellcheck disable=SC1091
  . /etc/os-release
  validar_entradas

  step "Verificando o servidor"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    info "Docker já em funcionamento: a versão do sistema não importa."
  else
    verificar_sistema
  fi
  verificar_arquitetura
  verificar_recursos

  step "Pacotes básicos"; garantir_ferramentas
  step "Docker"; garantir_docker
  escolher_porta

  step "Código ($REPO @ $BRANCH)"; preparar_codigo
  cd "$DIR"

  step "Publicando a porta $PORTA"; escrever_override

  step "Construindo e subindo (a 1ª vez baixa o GOWA e leva alguns minutos)"
  docker compose up -d --build

  # O que de fato foi publicado (respeita um override editado por você).
  local pub bind host_check
  pub=$(docker port whatsbot 8080/tcp 2>/dev/null | head -1 || true)
  if [ -n "$pub" ]; then PORTA=${pub##*:}; bind=${pub%:*}; else bind=0.0.0.0; fi
  case "$bind" in 0.0.0.0|::|"") host_check=127.0.0.1 ;; *) host_check=$bind ;; esac

  step "Esperando o WhatsBot ficar saudável"
  local i ok=0
  for i in $(seq 1 60); do
    if curl -fsS -m 5 "http://${host_check}:${PORTA}/health" >/dev/null 2>&1; then ok=1; break; fi
    sleep 3
  done
  if [ "$ok" != 1 ]; then docker compose logs --tail 60; die "não respondeu em /health após 3 minutos."; fi

  local ip pubip
  ip=$(local_ip); if [ -z "$ip" ]; then ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true); fi
  [ -n "$ip" ] || die "não consegui descobrir o IP deste servidor."

  printf '\n\033[1;32mWhatsBot-Lite no ar!\033[0m\n\n'
  if [ "$host_check" != 127.0.0.1 ] || [ "$bind" = 127.0.0.1 ]; then
    echo "  Painel:     http://${host_check}:${PORTA}   (só acessível de dentro deste servidor)"
  else
    # Valida pelo IP da interface, o mesmo que o navegador vai usar.
    curl -fsS -m 8 "http://${ip}:${PORTA}/health" >/dev/null || die "responde em localhost mas não em ${ip}:${PORTA}."
    echo "  Painel:     http://${ip}:${PORTA}"
    if ip_privado "$ip"; then
      pubip=$(public_ip)
      if [ -n "$pubip" ] && [ "$pubip" != "$ip" ]; then
        echo "  Pela internet: http://${pubip}:${PORTA}   (libere a porta ${PORTA} no firewall do provedor)"
      else
        echo "  (este é o IP interno do servidor; fora da rede dele, use o IP público e libere a porta ${PORTA} no firewall)"
      fi
    fi
  fi
  cat <<EOF
  Logs:       cd ${DIR} && docker compose logs -f
  Atualizar:  rode este comando de novo
  Parar:      cd ${DIR} && docker compose down     (os dados ficam nos volumes)

  Esta instalação é por IP e porta, em HTTP, pensada para rede interna.
  O painel não tem senha: não exponha esta porta direto na internet.

EOF
}

main "$@"
