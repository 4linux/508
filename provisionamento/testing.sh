#!/bin/bash

# ============================================================
#  testing.sh — CentOS Linux 8 (EOL) usando Vault + EPEL Archive
#  Instala: OpenSCAP, SCAP Workbench, (OWASP ZAP se disponível), GUI mínima
#  Tolerante a pacotes ausentes
# ============================================================

set -o pipefail
LOG="/var/log/vagrant_provision.log"

DEPS_PACKAGES="unzip wget vim tree python3 python3-pip python3-setuptools xorg-x11-xauth dnf-plugins-core"
# Nomes “preferidos”; alguns podem não existir no EPEL 8, então tratamos fallback/ausência
PACKAGES="git openscap-scanner scap-security-guide scap-workbench owasp-zap"
GUI_PACKAGES="mesa-dri-drivers spice-vdagent xorg-x11-server-Xorg xorg-x11-xinit xterm fluxbox mesa-demos"
PIP_PACKAGES="zap-cli-v2"

validateCommand() {
  if [ $? -eq 0 ]; then
    echo "[OK] $1"
  else
    echo "[ERROR] $1"
    exit 1
  fi
}

log_warn() {
  echo "[WARN] $1"
  echo "[WARN] $1" >> "$LOG"
}

sudo date >> "$LOG"

# --- SSH root key ---
if ! sudo test -f /root/.ssh/id_rsa; then
  sudo mkdir -p /root/.ssh/
  sudo cp /tmp/devsecops.pem /root/.ssh/id_rsa
  sudo cp /tmp/devsecops.pub /root/.ssh/authorized_keys
  sudo chmod 600 /root/.ssh/id_rsa
  validateCommand "Preparando SSH KEY"
else
  echo "[OK] SSH KEY"
fi

# --- Repos: Vault (CentOS 8.5) + EPEL Archive ---
sudo mkdir -p /etc/yum.repos.d.disabled
sudo mv /etc/yum.repos.d/*.repo /etc/yum.repos.d.disabled/ 2>/dev/null || true

sudo tee /etc/yum.repos.d/CentOS-Vault-8.5.repo >/dev/null <<'EOF'
[baseos]
name=CentOS-8.5 - BaseOS - Vault
baseurl=https://vault.centos.org/8.5.2111/BaseOS/x86_64/os/
enabled=1
gpgcheck=0

[appstream]
name=CentOS-8.5 - AppStream - Vault
baseurl=https://vault.centos.org/8.5.2111/AppStream/x86_64/os/
enabled=1
gpgcheck=0

[powertools]
name=CentOS-8.5 - PowerTools - Vault
baseurl=https://vault.centos.org/8.5.2111/PowerTools/x86_64/os/
enabled=1
gpgcheck=0

[extras]
name=CentOS-8.5 - Extras - Vault
baseurl=https://vault.centos.org/8.5.2111/extras/x86_64/os/
enabled=1
gpgcheck=0
EOF

sudo tee /etc/yum.repos.d/epel-archive.repo >/dev/null <<'EOF'
[epel]
name=EPEL 8 - Archive - Everything
baseurl=https://archive.fedoraproject.org/pub/epel/8/Everything/x86_64/
enabled=1
gpgcheck=0
EOF

sudo dnf -y clean all >/dev/null 2>>"$LOG"
sudo dnf -y makecache >/dev/null 2>>"$LOG"
validateCommand "Configuração de repositórios (Vault/EPEL Archive)"

# (Opcional) Módulo do Node.js — ignore erros (não é crítico)
sudo dnf -y module reset nodejs >/dev/null 2>>"$LOG" || true
sudo dnf -y module enable nodejs:14 >/dev/null 2>>"$LOG" || true

# --- Dependências base ---
sudo dnf -y install ${DEPS_PACKAGES} >/dev/null 2>>"$LOG"
validateCommand "Dependências base"

# Node opcional
sudo dnf -y install nodejs >/dev/null 2>>"$LOG" || log_warn "Node.js não disponível (ok, opcional)"
echo "[OK] Node.js (opcional)"

# ------------ Instalação tolerante a ausências ------------
# Função que testa se um pacote está disponível nos repositórios atuais
is_available() {
  local pkg="$1"
  # list available retorna 0 se encontrar; info também ajuda quando já estiver instalado
  sudo dnf -q list --available "$pkg" >/dev/null 2>&1 || sudo dnf -q info "$pkg" >/dev/null 2>&1
}

# Monta lista de pacotes realmente instaláveis
AVAILABLE_PKGS=()

# Primeiro, trate o caso especial do ZAP (pacote pode chamar "owasp-zap" ou "zaproxy")
if is_available "owasp-zap"; then
  AVAILABLE_PKGS+=("owasp-zap")
elif is_available "zaproxy"; then
  AVAILABLE_PKGS+=("zaproxy")
  log_warn "Usando 'zaproxy' no lugar de 'owasp-zap'"
else
  log_warn "OWASP ZAP não encontrado nos repositórios (vou seguir sem ele)"
fi

# Demais pacotes (PACKAGES sem owasp-zap já tratado)
for pkg in git openscap-scanner scap-security-guide scap-workbench; do
  if is_available "$pkg"; then
    AVAILABLE_PKGS+=("$pkg")
  else
    log_warn "Pacote ausente: $pkg"
  fi
done

# GUI (opcional; instala só o que existir)
for pkg in ${GUI_PACKAGES}; do
  if is_available "$pkg"; then
    AVAILABLE_PKGS+=("$pkg")
  else
    log_warn "Pacote GUI ausente: $pkg"
  fi
done

if [ ${#AVAILABLE_PKGS[@]} -gt 0 ]; then
  sudo dnf -y install "${AVAILABLE_PKGS[@]}" >/dev/null 2>>"$LOG"
  validateCommand "Instalação de Pacotes"
else
  log_warn "Nenhum pacote disponível para instalar (verifique repositórios/rede)"
fi
# -----------------------------------------------------------

# --- Python / pip ---
python3 -m pip install -q ${PIP_PACKAGES} >/dev/null 2>>"$LOG" || log_warn "pip: falha instalando ${PIP_PACKAGES}"
echo "[OK] Pacotes Python (tolerante)"

# ArcherySec CLI
sudo python3 -m pip install archerysec-cli --force -q >/dev/null 2>>"$LOG" || log_warn "pip: falha instalando archerysec-cli"
echo "[OK] Instala Archerysec (tolerante)"

# --- Symlinks do ZAP (se o binário existir) ---
if [ ! -e /usr/bin/zap.sh ]; then
  if [ -x /usr/share/owasp-zap/zap.sh ]; then
    sudo ln -s /usr/share/owasp-zap/zap.sh /usr/bin/zap.sh
  elif [ -x /usr/share/zaproxy/zap.sh ]; then
    sudo ln -s /usr/share/zaproxy/zap.sh /usr/bin/zap.sh
  fi

  if [ -x /usr/local/bin/zap-cli-v2 ]; then
    sudo ln -s /usr/local/bin/zap-cli-v2 /usr/bin/zap-cli-v2
  fi
  echo "[OK] Conf. Binários OWASP ZAP (se presente)"
else
  echo "[OK] Binário OWASP ZAP"
fi

# --- X11 Forwarding (Xauthority) ---
if ! grep -q Xauthority /root/.bashrc 2>/dev/null; then
  echo 'sudo cp /home/vagrant/.Xauthority /root/.Xauthority' | sudo tee -a /root/.bashrc >/dev/null
  echo "LANG=en_US.UTF-8" | sudo tee -a /etc/environment >/dev/null
  echo "LC_ALL=en_US.UTF-8" | sudo tee -a /etc/environment >/dev/null
  validateCommand "Configurando Xauthority"
else
  echo "[OK] Xauthority"
fi

# --- OpenSCAP (ajustes CentOS 8) ---
SG_PATH="/usr/share/xml/scap/ssg/content"

if [ -d /opt/openscap/cpe ]; then
  sudo cp /opt/openscap/cpe/*.xml /usr/share/openscap/cpe/ 2>>"$LOG" || true
fi

if [ -d "$SG_PATH" ]; then
  for FILE in $(ls $SG_PATH/ssg-rhel8-* 2>/dev/null); do
    TARGET="${FILE//rhel8/centos8}"
    if [ ! -e "$TARGET" ]; then
      sudo cp "$FILE" "$TARGET"
      sudo sed -i \
        -e 's|idref="cpe:/o:redhat:enterprise_linux|idref="cpe:/o:centos:centos|g' \
        -e 's|ref_id="cpe:/o:redhat:enterprise_linux|ref_id="cpe:/o:centos:centos|g' \
        "$TARGET"
    fi
  done
  echo "[OK] Configuração do OpenSCAP"
else
  echo "[OK] OpenSCAP (conteúdo não encontrado, ignorando ajuste)"
fi

echo "[OK] Provisionamento finalizado (testing)"

