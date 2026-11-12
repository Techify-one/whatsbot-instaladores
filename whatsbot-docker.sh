#!/usr/bin/env bash
# =====================================================================
#  WhatsBot-Lite — instalação com Docker
#  Ubuntu ou Debian limpo, como root. Sem perguntas.
#
#    bash <(curl -fsSL https://scripts.techify.site/whatsbot-docker)
#    bash <(wget -qO- https://scripts.techify.site/whatsbot-docker)    # sem curl
#
#  Opcional (antes do comando):  PORTA=8081   FORCAR=1
#  Pode rodar de novo: atualiza o WhatsBot e preserva os dados.
# =====================================================================
set -Eeuo pipefail

REPO="${REPO:-https://github.com/Techify-one/whatsbot-lite}"
BRANCH="${BRANCH:-main}"
DIR="${DIR:-/opt/whatsbot}"
PORTA="${PORTA:-}"
FORCAR="${FORCAR:-0}"   # 1 = segue sem perguntar quando o sistema não está na lista recomendada

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mAviso:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

have_tty()  { { : </dev/tty; } 2>/dev/null; }
port_busy() { ss -ltn "( sport = :$1 )" 2>/dev/null | awk 'NR>1' | grep -q .; }
local_ip()  { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }
APT="apt-get -o DPkg::Lock::Timeout=300"

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

  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) warn "arquitetura $(uname -m): só x86_64 e arm64 têm o motor do WhatsApp (GOWA) pronto."; confirmar_continuar ;;
  esac
}

verificar_recursos() {
  local mem disk
  mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  disk=$(df -Pm / | awk 'NR==2{print $4}')
  if [ "$mem" -lt 1800 ];    then warn "só ${mem} MB de RAM; o recomendado são 2048 MB ou mais (a construção da imagem pode falhar)."; fi
  if [ "$disk" -lt 8000 ];   then warn "só ${disk} MB livres em /; o recomendado são 10 GB ou mais."; fi
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
  $APT install -y -qq ca-certificates curl wget git iproute2 >/dev/null
}

instalar_docker() {
  if docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    info "Docker já instalado: $(docker --version)"
  else
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  # Em LXC do Proxmox o Docker só roda com "Nesting" ligado (Options > Features).
  if ! docker run --rm hello-world >/dev/null 2>&1; then
    die "o Docker não consegue rodar containers aqui. Se isto é um LXC do Proxmox: marque 'Nesting' \
em Options > Features (no host: pct set <ID> --features nesting=1), reinicie o container e rode de novo."
  fi
  info "Docker OK"
}

escolher_porta() {
  # Reexecução: o container já publica uma porta; mantém.
  local atual
  atual=$(docker port whatsbot 8080/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' || true)
  if [ -n "$atual" ]; then PORTA=$atual; return 0; fi
  if [ -n "$PORTA" ]; then
    [[ "$PORTA" =~ ^[0-9]+$ ]] && [ "$PORTA" -ge 1 ] && [ "$PORTA" -le 65535 ] || die "PORTA inválida: $PORTA"
    if port_busy "$PORTA"; then die "a porta $PORTA já está em uso neste servidor. Escolha outra: PORTA=8081"; fi
    return 0
  fi
  local p=8080
  while port_busy "$p"; do
    p=$((p + 1))
    if [ "$p" -gt 8099 ]; then die "não achei porta livre entre 8080 e 8099. Use PORTA=<número livre>."; fi
  done
  if [ "$p" != 8080 ]; then info "a porta 8080 está ocupada; usando a $p."; fi
  PORTA=$p
}

main() {
  [ "$(id -u)" -eq 0 ] || die "rode como root (use: sudo -i)"
  step "Verificando o servidor"
  verificar_sistema
  verificar_recursos

  step "Pacotes básicos"; apt_preparar
  step "Docker"; instalar_docker
  escolher_porta

  step "Código ($REPO @ $BRANCH)"
  if [ -d "$DIR/.git" ]; then
    git -C "$DIR" pull --ff-only
  else
    if [ -e "$DIR" ] && [ -n "$(ls -A "$DIR")" ]; then die "$DIR existe e não é um clone do WhatsBot"; fi
    git clone --depth 1 --branch "$BRANCH" "$REPO" "$DIR"
  fi
  cd "$DIR"

  step "Publicando a porta $PORTA"
  # O compose do repo só tem "expose" (feito para proxy/Coolify); para acessar por IP:porta
  # publicamos a porta num override, sem mexer em arquivo versionado.
  cat > docker-compose.override.yaml <<EOF
services:
  whatsbot:
    ports:
      - "${PORTA}:8080"
EOF

  step "Construindo e subindo (a 1ª vez baixa o GOWA e leva alguns minutos)"
  docker compose up -d --build

  step "Esperando o WhatsBot ficar saudável"
  local i ok=0
  for i in $(seq 1 60); do
    if curl -fsS -m 5 "http://127.0.0.1:${PORTA}/health" >/dev/null 2>&1; then ok=1; break; fi
    sleep 3
  done
  if [ "$ok" != 1 ]; then docker compose logs --tail 60; die "não respondeu em /health após 3 minutos"; fi

  local ip; ip=$(local_ip)
  if [ -z "$ip" ]; then ip=$(hostname -I | awk '{print $1}'); fi
  # Valida pelo IP da interface, o mesmo que o navegador vai usar.
  curl -fsS -m 8 "http://${ip}:${PORTA}/health" >/dev/null || die "responde em localhost mas não em ${ip}:${PORTA}"

  printf '\n\033[1;32mWhatsBot-Lite no ar!\033[0m\n'
  cat <<EOF

  Painel:     http://${ip}:${PORTA}
  Logs:       cd ${DIR} && docker compose logs -f
  Atualizar:  rode este comando de novo
  Parar:      cd ${DIR} && docker compose down     (os dados ficam nos volumes)

  Esta instalação é por IP e porta, em HTTP, pensada para rede interna.
  O painel não tem senha: não exponha esta porta direto na internet.

EOF
}

main "$@"
