#!/bin/bash

# =============================================================================
# CONFIGURACIÓN - VAULT (DESA) - [OPENSHIFT OPERATOR]
# =============================================================================
# CARACTERÍSTICAS:
#   _ NAMESPACE : ${NAMESPACE}   ← definido en sección PARÁMETROS | Pod: ${VAULT_POD_NAME}
#   _ PROTOCOLO : HTTP (sin TLS) — VAULT_ADDR http://127.0.0.1:8200
#   _ AUTH      : root token desde secret vault-init-credentials
#                 → secret vault-keys → $VAULT_ROOT_TOKEN
#   _ ENGINES   : KV v2 (secret/), Database (MariaDB), Transit, PKI
#   _ POLICIES  : una por recurso (mínimo privilegio)
#   _ USUARIOS  : userpass → ibm-app con todas las policies
#   _ SEGURIDAD : sin TLS — solo para desarrollo/laboratorio
#
# PRERREQUISITOS:
#   1. NAMESPACE "${NAMESPACE}" existente: $ oc create namespace ${NAMESPACE}
#   2. IBM ENTITLEMENT-KEY aplicado en el NAMESPACE "${NAMESPACE}" antes del SCRIPT de Vault:
#      $ oc create secret docker-registry ibm-entitlement-key \
#          --docker-server=cp.icr.io --docker-username=cp \
#          --docker-password=<ENTITLEMENT_KEY> -n ${NAMESPACE}
#   3. Instalación de Vault previa con SCRIPT: [1_Script_Instalacion_Vault_[Operator]_DESA.sh]
#   4. Autenticación en OPENSHIFT activa: $ oc login ...
#   5. Instalación del OPERATOR: 'VAULT-SECRET-OPERATOR' en todos los NAMESPACES.
#
# REQUERIMIENTOS DE INFRAESTRUCTURA:
#   Este script no despliega recursos propios — los recursos son los del pod vault-0
#   levantado por el script de instalación correspondiente: '1_Script_Instalacion_Vault_[Operator]_DESA.sh' 
#
# USO:
#   Es necesario el seteo del TOKEN obtenido en la INSTALACIÓN por medio del VAULT_ROOT_TOKEN (ya que el ENDPOINT de VAULT es HTTPs):
#   $ export VAULT_ROOT_TOKEN='hvs.xxxx' && sh ./3_Script_Configuracion_Vault_[Operator]_DESA.sh --modalidad=install
#   $ export VAULT_ROOT_TOKEN='hvs.xxxx' && sh ./3_Script_Configuracion_Vault_[Operator]_DESA.sh --modalidad=delete
#   EJEMPLO: 
#   ==> $ export VAULT_ROOT_TOKEN='hvs.wYqM6My4pNqVrEdigwdmf0dR' && sh ./3_Script_Configuracion_Vault_[Operator]_DESA.sh --modalidad=install 
#   ==> $ export VAULT_ROOT_TOKEN='hvs.wYqM6My4pNqVrEdigwdmf0dR' && sh ./3_Script_Configuracion_Vault_[Operator]_DESA.sh --modalidad=delete 
# =============================================================================

set -e

# --- Namespace y pod (HTTP, sin TLS real) ---
NAMESPACE="vault"
VAULT_POD_NAME="vault-0"
VAULT_ADDR_INTERNAL="http://127.0.0.1:8200"

# --- KV secrets ---
KV_MOUNT="secret"

SECRET_IBM_01_NAME="secret_ibm_01"
SECRET_IBM_01_USUARIO="rguerra"
SECRET_IBM_01_PASSWORD="ibmabc123"
SECRET_IBM_01_URL="http://localhost:9080/liberty-employee-service/ibm/employeeService/getEmpleados"

SECRET_IBM_02_NAME="secret_ibm_02"
SECRET_IBM_02_USUARIO="cguerra"
SECRET_IBM_02_PASSWORD="ibm12345678"
SECRET_IBM_02_CADENA="jdbc:mysql://localhost:3306/DBIBM?useSSL=false&serverTimezone=UTC&rewriteBatchedStatements=true"

# --- Database secrets engine (MariaDB) ---
DB_CONFIG_NAME="mariadb-app"
DB_ROLE_NAME="mariadb-app"
DB_PLUGIN_NAME="mysql-database-plugin"
DB_CONNECTION_URL="{{username}}:{{password}}@tcp(mariadb.dummy-database.svc.cluster.local:3306)/"
DB_ALLOWED_ROLES="mariadb-app"
DB_USERNAME="root"
DB_PASSWORD="rootpassword"
DB_DEFAULT_TTL="1h"
DB_MAX_TTL="24h"

# --- Transit secrets engine ---
TRANSIT_KEY_NAME="ibm-transit-key"

# --- PKI secrets engine (TTL reducido para desarrollo) ---
PKI_MOUNT="pki"
PKI_MAX_LEASE_TTL="8760h"   # 1 año — suficiente para desarrollo
PKI_ROOT_COMMON_NAME="midominioibm.com Root CA"
PKI_ROOT_TTL="8760h"                 
VAULT_ROUTE_URL="https://${RELEASE_NAME}-ui-${NAMESPACE}.apps.itz-l7d2s4.infra01-lb.wdc07.techzone.ibm.com"

PKI_DEV_ROLE="dev-role"
PKI_DEV_ALLOWED_DOMAIN="dev.local"
PKI_DEV_CERT_COMMON_NAME="app.dev.local"
PKI_DEV_CERT_ALT_NAMES="localhost,app.dev.local"
PKI_DEV_CERT_IP_SANS="127.0.0.1"
PKI_DEV_CERT_TTL="1h"

PKI_WEB_ROLE="ibm-web-server"
PKI_WEB_ALLOWED_DOMAIN="midominioibm.com"
PKI_WEB_MAX_TTL="720h"
PKI_WEB_TTL="720h"

# --- Policies (una por engine, mínimo privilegio) ---
POLICY_KV_01="policy_ibm_01"
POLICY_KV_02="policy_ibm_02"
POLICY_DB_01="policy_db_01"
POLICY_TRANSIT_01="policy_transit_01"
POLICY_CERTIFICATE_01="policy_certificate-01"

# --- Usuario de aplicación (auth method userpass) ---
APP_USERNAME="ibm-app"
APP_PASSWORD="12345678"
APP_TOKEN_POLICIES="default,policy_ibm_01,policy_ibm_02,policy_db_01,policy_transit_01,policy_certificate-01"

# Busca el root token en: secret vault-init-credentials → vault-keys → $VAULT_ROOT_TOKEN
resolve_vault_token() {
  if [ -n "${VAULT_ROOT_TOKEN:-}" ]; then
    echo "${VAULT_ROOT_TOKEN}"; return 0
  fi
  local token
  # Prioridad 1: secret del script Operator DESA
  token=$(oc get secret "${NAMESPACE}-init-credentials" -n "${NAMESPACE}" \
            -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [ -n "${token}" ] && echo "${token}" && return 0
  # Prioridad 2: secret del Helm chart
  token=$(oc get secret "${NAMESPACE}-keys" -n "${NAMESPACE}" \
            -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [ -n "${token}" ] && echo "${token}" && return 0

  echo "ERROR: No se pudo obtener el Root Token de Vault." >&2
  echo "  export VAULT_ROOT_TOKEN='hvs.XXXX' && sh $0 --modalidad=install" >&2
  echo "  oc get secret ${NAMESPACE}-init-credentials -n ${NAMESPACE} -o jsonpath='{.data.root-token}' | base64 -d" >&2
  exit 1
}

print_cmd() {
  echo ""; echo ">> $1"; echo ""
}

# Envía el script al pod por stdin — HTTP, sin CACERT
run_vault_cmd() {
  print_cmd "$1"
  printf 'export VAULT_TOKEN=%s\nexport VAULT_ADDR=%s\n%s\n' \
    "${ROOT_TOKEN}" "${VAULT_ADDR_INTERNAL}" "$1" \
    | oc exec -i -n "${NAMESPACE}" "${VAULT_POD_NAME}" -- sh
}

run_vault_cmd_allow_error() {
  print_cmd "$1"
  printf 'export VAULT_TOKEN=%s\nexport VAULT_ADDR=%s\n%s\n' \
    "${ROOT_TOKEN}" "${VAULT_ADDR_INTERNAL}" "$1" \
    | oc exec -i -n "${NAMESPACE}" "${VAULT_POD_NAME}" -- sh || true
}

validate_environment() {
  echo "===> 1. VALIDANDO POD Y ESTADO DE VAULT"
  oc get pod "${VAULT_POD_NAME}" -n "${NAMESPACE}"
  echo ""

  SEAL_STATUS=$(oc exec -n "${NAMESPACE}" "${VAULT_POD_NAME}" -- \
    sh -c "export VAULT_ADDR='${VAULT_ADDR_INTERNAL}'; vault status -format=json 2>/dev/null" || true)

  if echo "${SEAL_STATUS}" | grep -q '"sealed":true'; then
    echo "ERROR: Vault está SEALED. Ejecuta unseal antes de configurar."
    echo "  oc exec -it vault-0 -n ${NAMESPACE} -- vault operator unseal <unseal_key>"
    exit 1
  fi
  echo "    UNSEALED. Continuando..."; echo ""
}

do_install() {
  echo "===== [INSTALL — INICIO] ====="
  echo ""
  echo "===> 0. RESOLVIENDO ROOT TOKEN"
  ROOT_TOKEN=$(resolve_vault_token)
  echo "    OK (${ROOT_TOKEN:0:8}...)"; echo ""

  validate_environment

  echo "===> 2. AUTH METHOD USERPASS"
  run_vault_cmd_allow_error "vault auth enable userpass"
  echo ""

  echo "===> 3. SECRETS ENGINES (kv-v2, database, transit, pki)"
  run_vault_cmd_allow_error "vault secrets enable -path=${KV_MOUNT} -version=2 kv"
  run_vault_cmd_allow_error "vault secrets enable database"
  run_vault_cmd_allow_error "vault secrets enable transit"
  run_vault_cmd_allow_error "vault secrets enable ${PKI_MOUNT}"
  run_vault_cmd "vault secrets tune -max-lease-ttl=${PKI_MAX_LEASE_TTL} ${PKI_MOUNT}"
  run_vault_cmd "vault secrets list"
  echo ""

  echo "===> 4. KV SECRETS"
  run_vault_cmd "vault kv put -mount=${KV_MOUNT} ${SECRET_IBM_01_NAME} \
    usuario='${SECRET_IBM_01_USUARIO}' \
    password='${SECRET_IBM_01_PASSWORD}' \
    url='${SECRET_IBM_01_URL}'"
  run_vault_cmd "vault kv put -mount=${KV_MOUNT} ${SECRET_IBM_02_NAME} \
    usuario='${SECRET_IBM_02_USUARIO}' \
    password='${SECRET_IBM_02_PASSWORD}' \
    cadena='${SECRET_IBM_02_CADENA}'"
  echo ""

  echo "===> 5. DATABASE ENGINE"
  run_vault_cmd "vault write database/config/${DB_CONFIG_NAME} \
    plugin_name='${DB_PLUGIN_NAME}' \
    connection_url='${DB_CONNECTION_URL}' \
    allowed_roles='${DB_ALLOWED_ROLES}' \
    username='${DB_USERNAME}' \
    password='${DB_PASSWORD}'"
  run_vault_cmd "vault write database/roles/${DB_ROLE_NAME} \
    db_name='${DB_CONFIG_NAME}' \
    creation_statements=\"CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}'; GRANT ALL PRIVILEGES ON mariadb.* TO '{{name}}'@'%';\" \
    revocation_statements=\"DROP USER IF EXISTS '{{name}}'@'%';\" \
    default_ttl='${DB_DEFAULT_TTL}' \
    max_ttl='${DB_MAX_TTL}'"
  echo ""

  echo "===> 6. TRANSIT ENGINE"
  run_vault_cmd "vault write -f transit/keys/${TRANSIT_KEY_NAME}"
  echo ""

  # PKI: CA raíz + URLs CRL + rol dev (dev.local) + rol web (midominioibm.com)
  echo "===> 7. PKI ENGINE"
  run_vault_cmd "vault write ${PKI_MOUNT}/root/generate/internal \
    common_name='${PKI_ROOT_COMMON_NAME}' ttl='${PKI_ROOT_TTL}'"
  run_vault_cmd "vault write ${PKI_MOUNT}/config/urls \
    issuing_certificates='${VAULT_ROUTE_URL}/v1/${PKI_MOUNT}/ca' \
    crl_distribution_points='${VAULT_ROUTE_URL}/v1/${PKI_MOUNT}/crl'"
  run_vault_cmd "vault write ${PKI_MOUNT}/roles/${PKI_DEV_ROLE} \
    allowed_domains='${PKI_DEV_ALLOWED_DOMAIN}' \
    allow_subdomains=true allow_bare_domains=true \
    allow_localhost=true allow_ip_sans=true max_ttl='24h'"
  run_vault_cmd "vault write ${PKI_MOUNT}/issue/${PKI_DEV_ROLE} \
    common_name='${PKI_DEV_CERT_COMMON_NAME}' \
    alt_names='${PKI_DEV_CERT_ALT_NAMES}' \
    ip_sans='${PKI_DEV_CERT_IP_SANS}' ttl='${PKI_DEV_CERT_TTL}'"
  run_vault_cmd "vault write ${PKI_MOUNT}/roles/${PKI_WEB_ROLE} \
    allowed_domains='${PKI_WEB_ALLOWED_DOMAIN}' \
    allow_subdomains=true allow_bare_domains=true \
    allow_localhost=true allow_ip_sans=true \
    max_ttl='${PKI_WEB_MAX_TTL}' ttl='${PKI_WEB_TTL}'"
  echo ""

  echo "===> 8. POLICIES"
  run_vault_cmd "vault policy write ${POLICY_KV_01} - <<'EOF'
path \"${KV_MOUNT}/data/${SECRET_IBM_01_NAME}\" { capabilities = [\"read\"] }
EOF"
  run_vault_cmd "vault policy write ${POLICY_KV_02} - <<'EOF'
path \"${KV_MOUNT}/data/${SECRET_IBM_02_NAME}\" { capabilities = [\"read\"] }
EOF"
  run_vault_cmd "vault policy write ${POLICY_DB_01} - <<'EOF'
path \"database/creds/${DB_ROLE_NAME}\" { capabilities = [\"read\"] }
EOF"
  run_vault_cmd "vault policy write ${POLICY_TRANSIT_01} - <<'EOF'
path \"transit/keys/*\"    { capabilities = [\"create\",\"update\",\"read\",\"list\"] }
path \"transit/encrypt/*\" { capabilities = [\"update\"] }
path \"transit/decrypt/*\" { capabilities = [\"update\"] }
path \"transit/rewrap/*\"  { capabilities = [\"update\"] }
EOF"
  run_vault_cmd "vault policy write ${POLICY_CERTIFICATE_01} - <<'EOF'
path \"${PKI_MOUNT}/issue/*\"  { capabilities = [\"update\"] }
path \"${PKI_MOUNT}/revoke\"   { capabilities = [\"update\"] }
path \"${PKI_MOUNT}/roles/*\"  { capabilities = [\"read\",\"create\",\"update\",\"list\"] }
path \"${PKI_MOUNT}/cert/*\"   { capabilities = [\"read\",\"list\"] }
path \"${PKI_MOUNT}/cert/ca\"  { capabilities = [\"read\"] }
path \"${PKI_MOUNT}/cert/crl\" { capabilities = [\"read\"] }
path \"${PKI_MOUNT}/crl\"      { capabilities = [\"read\"] }
EOF"
  echo ""

  echo "===> 9. USUARIO USERPASS: ${APP_USERNAME}"
  run_vault_cmd "vault write auth/userpass/users/${APP_USERNAME} \
    password='${APP_PASSWORD}' token_policies='${APP_TOKEN_POLICIES}'"
  echo ""

  echo "===> 10. VALIDACIÓN FINAL"
  run_vault_cmd "vault login -method=userpass username='${APP_USERNAME}' password='${APP_PASSWORD}'"
  run_vault_cmd "vault kv get -mount=${KV_MOUNT} ${SECRET_IBM_01_NAME}"
  # Database creds requiere MariaDB activo; se permite fallo en desarrollo
  run_vault_cmd_allow_error "vault read database/creds/${DB_ROLE_NAME}"
  echo ""

  echo "===== [INSTALL — FIN] ====="
}

do_delete() {
  echo "===== [DELETE — INICIO] ====="
  echo "  ADVERTENCIA: Se eliminarán TODOS los recursos. 10s para cancelar (Ctrl+C)..."
  sleep 10; echo ""

  echo "===> 0. RESOLVIENDO ROOT TOKEN"
  ROOT_TOKEN=$(resolve_vault_token)
  echo "    OK (${ROOT_TOKEN:0:8}...)"; echo ""

  validate_environment

  echo "===> D1. USUARIO USERPASS"
  run_vault_cmd_allow_error "vault delete auth/userpass/users/${APP_USERNAME}"; echo ""

  echo "===> D2. POLICIES"
  run_vault_cmd_allow_error "vault policy delete ${POLICY_CERTIFICATE_01}"
  run_vault_cmd_allow_error "vault policy delete ${POLICY_TRANSIT_01}"
  run_vault_cmd_allow_error "vault policy delete ${POLICY_DB_01}"
  run_vault_cmd_allow_error "vault policy delete ${POLICY_KV_02}"
  run_vault_cmd_allow_error "vault policy delete ${POLICY_KV_01}"; echo ""

  echo "===> D3. PKI ENGINE"
  run_vault_cmd_allow_error "vault secrets disable ${PKI_MOUNT}"; echo ""

  echo "===> D4. TRANSIT ENGINE"
  run_vault_cmd_allow_error "vault secrets disable transit"; echo ""

  # Role y config antes de deshabilitar el engine
  echo "===> D5. DATABASE ENGINE"
  run_vault_cmd_allow_error "vault delete database/roles/${DB_ROLE_NAME}"
  run_vault_cmd_allow_error "vault delete database/config/${DB_CONFIG_NAME}"
  run_vault_cmd_allow_error "vault secrets disable database"; echo ""

  # delete borra versión activa; metadata delete borra el historial completo
  echo "===> D6. KV SECRETS"
  run_vault_cmd_allow_error "vault kv delete -mount=${KV_MOUNT} ${SECRET_IBM_01_NAME}"
  run_vault_cmd_allow_error "vault kv metadata delete -mount=${KV_MOUNT} ${SECRET_IBM_01_NAME}"
  run_vault_cmd_allow_error "vault kv delete -mount=${KV_MOUNT} ${SECRET_IBM_02_NAME}"
  run_vault_cmd_allow_error "vault kv metadata delete -mount=${KV_MOUNT} ${SECRET_IBM_02_NAME}"; echo ""

  echo "===> D7. KV ENGINE"
  run_vault_cmd_allow_error "vault secrets disable ${KV_MOUNT}"; echo ""

  # auth disable revoca todos los tokens activos emitidos por este método
  echo "===> D8. AUTH METHOD USERPASS"
  run_vault_cmd_allow_error "vault auth disable userpass"; echo ""

  echo "===> D9. ESTADO FINAL"
  run_vault_cmd "vault secrets list"
  run_vault_cmd "vault auth list"; echo ""

  echo "===== [DELETE — FIN] ====="
}

usage() {
  echo ""
  echo "Uso: sh $0 --modalidad=<install|delete>"
  echo ""
  echo "  install  Configura: userpass, KV, Database, Transit, PKI, policies, usuario"
  echo "  delete   Elimina todos los recursos (10s de gracia para cancelar)"
  echo ""
  echo "  Opcional: export VAULT_ROOT_TOKEN='hvs.XXXX' antes de invocar"
  echo ""
  exit 1
}

MODE=""
for ARG in "$@"; do
  case "${ARG}" in
    --modalidad=*) MODE="${ARG#--modalidad=}" ;;
  esac
done

case "${MODE}" in
  install) do_install ;;
  delete)  do_delete  ;;
  *)
    echo "ERROR: modalidad '${MODE}' no reconocida o no especificada."
    usage
    ;;
esac
