#!/bin/bash

# ============================================================
# logging.sh — CentOS Linux 8 (EOL)
# Repos: CentOS Vault 8.5 + EPEL Archive (+ HashiCorp se funcionar)
# Instala MariaDB, Consul e Vault (com fallback para binários)
# Tolerante a pacotes ausentes / repositórios instáveis
# ============================================================

set -o pipefail

LOG="/var/log/vagrant_provision.log"
# garante PATH com /usr/local/bin mesmo em shells não-login
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Pacotes base (nomes do EL8)
DEPS_PACKAGES="vim-enhanced tree wget curl redhat-rpm-config gcc httpd-tools ca-certificates"
# python*-devel pode variar; tratar como opcional
OPTIONAL_DEVEL="python3-devel python36-devel"
BASE_PACKAGES="mariadb mariadb-server"

# HashiCorp (RPM, se o repo funcionar)
HASHI_PACKAGES="vault consul"

# Fallback (binários) — tente várias versões até baixar com sucesso
VAULT_VERSIONS=("1.18.3" "1.17.6" "1.16.7" "1.15.9")
CONSUL_VERSIONS=("1.19.2" "1.18.2" "1.17.6" "1.16.10")

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

is_available() {
  local pkg="$1"
  sudo dnf -q list --available "$pkg" >/dev/null 2>&1 || sudo dnf -q info "$pkg" >/dev/null 2>&1
}

safe_install_list() {
  local -a to_install=()
  for pkg in "$@"; do
    if is_available "$pkg"; then
      to_install+=("$pkg")
    else
      log_warn "Pacote ausente: $pkg"
    fi
  done
  if [ ${#to_install[@]} -gt 0 ]; then
    sudo dnf -y install "${to_install[@]}" >/dev/null 2>>"$LOG"
  fi
}

download_hashicorp_binary() {
  local name="$1"               # vault | consul
  shift
  local -a versions=("$@")      # array de versões para tentar

  # Garante unzip
  if ! command -v unzip >/dev/null 2>&1; then
    sudo dnf -y install unzip >/dev/null 2>>"$LOG" || true
  fi

  for ver in "${versions[@]}"; do
    local url="https://releases.hashicorp.com/${name}/${ver}/${name}_${ver}_linux_amd64.zip"
    echo "[INFO] Tentando ${name} ${ver} (binário)..."
    if curl -fsSL "$url" -o "/tmp/${name}.zip" 2>>"$LOG"; then
      sudo unzip -o "/tmp/${name}.zip" -d /usr/local/bin >/dev/null 2>>"$LOG" || continue
      sudo chmod +x "/usr/local/bin/${name}"
      # symlink para /usr/bin para garantir visibilidade em todos os ambientes
      sudo ln -sf "/usr/local/bin/${name}" "/usr/bin/${name}" 2>>"$LOG" || true
      echo "[OK] ${name} ${ver} instalado em /usr/local/bin/${name}"
      return 0
    fi
  done
  log_warn "Falha ao baixar ${name} (todas as versões testadas)."
  return 1
}

install_vault_consul() {
  # 1) Tenta via repo HashiCorp
  if [ ! -f /etc/yum.repos.d/hashicorp.repo ]; then
    sudo tee /etc/yum.repos.d/hashicorp.repo >/dev/null <<'EOF'
[hashicorp]
name=HashiCorp Stable - RHEL 8
baseurl=https://rpm.releases.hashicorp.com/RHEL/8/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://rpm.releases.hashicorp.com/gpg
EOF
    # importa chave; se falhar, desliga gpgcheck para não travar
    if ! sudo rpm --import https://rpm.releases.hashicorp.com/gpg >/dev/null 2>>"$LOG"; then
      log_warn "Falha ao importar GPG da HashiCorp; desabilitando gpgcheck"
      sudo sed -i 's/^gpgcheck=1/gpgcheck=0/' /etc/yum.repos.d/hashicorp.repo
    fi
    sudo dnf -y makecache >/dev/null 2>>"$LOG"
  fi

  # Verifica se os pacotes estão disponíveis e tenta instalar
  local any_available=0
  for p in ${HASHI_PACKAGES}; do
    if is_available "$p"; then any_available=1; fi
  done

  if [ $any_available -eq 1 ]; then
    if sudo dnf -y install ${HASHI_PACKAGES} >/dev/null 2>>"$LOG"; then
      echo "[OK] HashiCorp (vault/consul) via RPM"
      return 0
    fi
    log_warn "dnf install vault/consul falhou; vou tentar binário."
  else
    log_warn "Repo HashiCorp não trouxe vault/consul; tentando binário."
  fi

  # 2) Fallback: binários oficiais
  download_hashicorp_binary "vault" "${VAULT_VERSIONS[@]}" || true
  download_hashicorp_binary "consul" "${CONSUL_VERSIONS[@]}" || true

  # Checagem final por existência do executável (não depende do PATH)
  if { [ -x /usr/local/bin/vault ] || [ -x /usr/bin/vault ]; } \
     && { [ -x /usr/local/bin/consul ] || [ -x /usr/bin/consul ]; }; then
    echo "[OK] HashiCorp (vault/consul) via binários"
    return 0
  fi

  log_warn "Não foi possível instalar vault/consul (RPM e binário falharam)."
  return 1
}

# ------------------- INÍCIO DO PROVISIONAMENTO -------------------

sudo date >> "$LOG"

# --- SSH root key (como no seu script) ---
if ! sudo test -f /root/.ssh/id_rsa; then
  sudo mkdir -p /root/.ssh/
  sudo cp /tmp/devsecops.pem /root/.ssh/id_rsa
  sudo cp /tmp/devsecops.pub /root/.ssh/authorized_keys
  sudo chmod 600 /root/.ssh/id_rsa
  validateCommand "Preparando SSH KEY"
else
  echo "[OK] SSH KEY"
fi

# --- Copia git plugin & Rundeck infra (igual ao seu) ---
sudo cp /tmp/git-plugin-1.0.4.jar /root/git-plugin-1.0.4.jar >/dev/null 2>>"$LOG"
validateCommand "Copia git plugin"

if ! id -u rundeck >/dev/null 2>&1; then
  sudo useradd rundeck >/dev/null 2>>"$LOG"
fi
sudo mkdir -p /opt/rundeck/projects/ansible-hardening/ >/dev/null 2>>"$LOG"
sudo chown -R rundeck: /opt/rundeck/projects/ansible-hardening/ >/dev/null 2>>"$LOG"
sudo cp /tmp/devsecops.pem /home/rundeck/id_rsa >/dev/null 2>>"$LOG"
sudo chmod 600 /home/rundeck/id_rsa >/dev/null 2>>"$LOG"
sudo chown rundeck:rundeck /home/rundeck/id_rsa >/dev/null 2>>"$LOG"
validateCommand "Configuracoes gerais Rundeck"

sudo sed -i 's/77.30/56.30/g' /etc/profile >/dev/null 2>>"$LOG"
validateCommand "Configura profile"

# --- Repos: CentOS Vault 8.5 + EPEL Archive ---
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
validateCommand "Repositórios Vault/EPEL configurados"

# --- Instalações ---
# Dependências base + (opcional) headers Python
safe_install_list ${DEPS_PACKAGES} ${OPTIONAL_DEVEL}
validateCommand "Dependências base"

# MariaDB (cliente/servidor)
safe_install_list ${BASE_PACKAGES}
validateCommand "MariaDB (cliente/servidor)"

# Vault/Consul via repo HashiCorp ou fallback binário
install_vault_consul
validateCommand "HashiCorp (vault/consul)"

echo "[OK] Provisionamento finalizado (logging)"

# ------------------- (OPCIONAL) serviços em modo dev -------------------
# Descomente para rodar Consul e Vault em modo dev via systemd
# cat <<'UNIT' | sudo tee /etc/systemd/system/consul-dev.service >/dev/null
# [Unit]
# Description=Consul (dev)
# After=network.target
# [Service]
# ExecStart=/usr/bin/consul agent -dev -bind=0.0.0.0
# Restart=on-failure
# [Install]
# WantedBy=multi-user.target
# UNIT
# sudo systemctl daemon-reload
# sudo systemctl enable --now consul-dev
#
# cat <<'UNIT' | sudo tee /etc/systemd/system/vault-dev.service >/dev/null
# [Unit]
# Description=Vault (dev)
# After=network.target
# [Service]
# ExecStart=/usr/bin/vault server -dev -dev-listen-address=0.0.0.0:8200
# Environment=VAULT_ADDR=http://127.0.0.1:8200
# Restart=on-failure
# [Install]
# WantedBy=multi-user.target
# UNIT
# sudo systemctl daemon-reload
# sudo systemctl enable --now vault-dev
