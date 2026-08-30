#!/bin/bash

# =============================================================================
# MIGRACIÓN COMPLETA DE SECRETS ENTRE DOS INSTANCIAS VAULT
# =============================================================================
# MIGRA todos los ENGINEs con datos del Vault ORIGEN al Vault DESTINO.
#
# MODOS DE OPERACIÓN (seleccionar con MODO_CONEXION):
#
#   oc-exec   → Ambas INSTANCIAS Vault en el MISMO clúster OPENSHIFT.
#               Usa 'oc exec' para ejecutar comandos dentro del pod.
#               Requiere: oc login activo, POD_ORIGEN, POD_DESTINO, NS_ORIGEN, NS_DESTINO.
#
#   vault-cli → Las INSTANCIAS Vault pueden estar en DISTINTOS clusters,
#               distintos clouds, o en cualquier endpoint HTTPS accesible.
#               Usa el CLI 'vault' instalado en el host con VAULT_ADDR apuntando
#               al endpoint externo de cada instancia.
#               Requiere: vault CLI instalado, ADDR_ORIGEN, ADDR_DESTINO accesibles por red.
#               NO requiere: oc login, pods, namespaces.
#
# CARACTERÍSTICAS:
#   _ ENGINES   : KV v2, PKI, Transit, Database (cubbyhole/identity/sys excluidos)
#   _ SEGURIDAD : tokens root inyectados por variable — no persisten en disco
#   _ LIMITACIÓN: password de Database no se exporta — reconfiguración manual
#
# PRERREQUISITOS modo oc-exec:
#   1. Autenticación en OPENSHIFT activa: $ oc login ...
#   2. Ambas instancias Vault UNSEALED y accesibles por oc exec.
#
# PRERREQUISITOS modo vault-cli:
#   1. vault CLI instalado en el host que ejecuta el script.
#   2. ADDR_ORIGEN y ADDR_DESTINO accesibles por HTTPS desde el host.
#   3. Ambas instancias Vault UNSEALED.
#
# REQUERIMIENTOS DE INFRAESTRUCTURA:
#   Este script no despliega recursos propios — requiere que ambas instancias Vault
#   estén ya funcionando (UNSEALED) con suficientes recursos para atender las operaciones
#   de lectura (ORIGEN) y escritura (DESTINO) de todos los engines migrados.
#   _ CPU / MEMORIA / STORAGE : ver scripts de instalación de cada instancia Vault
#
# USO:
#   $ sh ./0_Script_Migracion_AllSecrets_entre_Vaults.sh
# =============================================================================

set -e
set -o pipefail

# grep retorna exit 1 cuando no hay match — todos los greps condicionales usan '|| true'.
unset VAULT_ADDR VAULT_TOKEN VAULT_NAMESPACE VAULT_CACERT

# =============================================================================
# PARÁMETROS — ÚNICA SECCIÓN A EDITAR
# =============================================================================

# -----------------------------------------------------------------------------
# MODO DE CONEXIÓN:
#   "oc-exec"   → mismo cluster OpenShift (usa oc exec)
#   "vault-cli" → endpoints distintos / distintos clusters (usa vault CLI en host)
# -----------------------------------------------------------------------------
MODO_CONEXION="oc-exec"

# --- Parámetros modo oc-exec (solo aplican si MODO_CONEXION="oc-exec") ---
NS_ORIGEN="vault"
POD_ORIGEN="vault-0"
NS_DESTINO="vault02"
POD_DESTINO="vault02-0"

# --- Parámetros modo vault-cli (solo aplican si MODO_CONEXION="vault-cli") ---
# Endpoints HTTPS externos de cada instancia Vault.
ADDR_ORIGEN="https://vault-ui-vault.apps.cluster-origen.example.com"
ADDR_DESTINO="https://vault-ui-vault.apps.cluster-destino.example.com"

# --- Tokens (aplican en ambos modos) ---
TOKEN_ORIGEN="hvs.07BI8kHPdBWuiMf0NrhDDE4N"
TOKEN_DESTINO="hvs.OYyPqI6OxR4OEwiaHJ6eTHF9"

# DRY_RUN="true" → solo lista, NO escribe en el DESTINO
DRY_RUN="false"

# Engines a migrar (dejar en "true" los que quieres migrar)
MIGRAR_KV="true"
MIGRAR_PKI="true"
MIGRAR_TRANSIT="true"
MIGRAR_DATABASE="true"

# --- Utilidades ---
print_step() {
  echo ""
  echo "============================================================"
  echo "  $1"
  echo "============================================================"
}

# -----------------------------------------------------------------------------
# exec_origen / exec_destino / exec_destino_kv_put
#
# Abstraen el mecanismo de ejecución según MODO_CONEXION:
#
#   oc-exec   → inyecta el comando por stdin a 'oc exec -i <pod>'
#               (el Vault escucha en 127.0.0.1:8200 dentro del pod)
#
#   vault-cli → ejecuta 'vault <cmd>' directamente en el host con
#               VAULT_ADDR y VAULT_TOKEN apuntando al endpoint externo.
#               Requiere vault CLI instalado en el host.
# -----------------------------------------------------------------------------

exec_origen() {
  if [ "${MODO_CONEXION}" = "vault-cli" ]; then
    VAULT_ADDR="${ADDR_ORIGEN}" VAULT_TOKEN="${TOKEN_ORIGEN}" VAULT_SKIP_VERIFY=true \
      sh -c "$1" 2>/dev/null || true
  else
    printf 'export VAULT_ADDR=https://127.0.0.1:8200\nvault login -tls-skip-verify %s >/dev/null 2>&1\n%s\n' \
      "${TOKEN_ORIGEN}" "$1" \
      | oc exec -i "${POD_ORIGEN}" -n "${NS_ORIGEN}" -- sh 2>/dev/null || true
  fi
}

exec_destino() {
  if [ "${MODO_CONEXION}" = "vault-cli" ]; then
    VAULT_ADDR="${ADDR_DESTINO}" VAULT_TOKEN="${TOKEN_DESTINO}" VAULT_SKIP_VERIFY=true \
      sh -c "$1" 2>/dev/null || true
  else
    printf 'export VAULT_ADDR=https://127.0.0.1:8200\nvault login -tls-skip-verify %s >/dev/null 2>&1\n%s\n' \
      "${TOKEN_DESTINO}" "$1" \
      | oc exec -i "${POD_DESTINO}" -n "${NS_DESTINO}" -- sh 2>/dev/null || true
  fi
}

# Escribe un secreto kv-v2 en el DESTINO.
# $1 = path (sin 'secret/'), $2 = pares key="value" (output del awk parser)
exec_destino_kv_put() {
  local kv_path="$1"
  local kv_pairs="$2"

  if [ "${MODO_CONEXION}" = "vault-cli" ]; then
    VAULT_ADDR="${ADDR_DESTINO}" VAULT_TOKEN="${TOKEN_DESTINO}" VAULT_SKIP_VERIFY=true \
      sh -c "vault kv put -tls-skip-verify secret/${kv_path} ${kv_pairs} 2>&1" 2>/dev/null || true
  else
    printf 'export VAULT_ADDR=https://127.0.0.1:8200\nvault login -tls-skip-verify %s >/dev/null 2>&1\nvault kv put -tls-skip-verify secret/%s %s 2>&1\n' \
      "${TOKEN_DESTINO}" "${kv_path}" "${kv_pairs}" \
      | oc exec -i "${POD_DESTINO}" -n "${NS_DESTINO}" -- sh 2>/dev/null || true
  fi
}

habilitar_engine_destino() {
  local mount="$1"
  local type="$2"
  local extra="$3"   # opciones adicionales (ej: -max-lease-ttl=...)
  local EXISTS
  EXISTS=$(exec_destino "vault secrets list -tls-skip-verify 2>/dev/null | grep '^${mount}/' || true")
  if [ -z "${EXISTS}" ]; then
    echo "  Habilitando engine '${mount}/' (${type}) en DESTINO..."
    if [ "${DRY_RUN}" = "false" ]; then
      exec_destino "vault secrets enable -path=${mount} ${extra} ${type} 2>&1 || true"
    else
      echo "  [DRY-RUN] vault secrets enable -path=${mount} ${extra} ${type}"
    fi
  else
    echo "  Engine '${mount}/' ya existe en DESTINO."
  fi
}

TOTAL_OK=0
TOTAL_SKIP=0
TOTAL_ERR=0

# Valida conectividad según el modo activo
print_step "VALIDANDO CONECTIVIDAD  [modo: ${MODO_CONEXION}]"

if [ "${MODO_CONEXION}" = "vault-cli" ]; then
  # Verificar que el CLI de vault está disponible en el host
  if ! command -v vault >/dev/null 2>&1; then
    echo "  ERROR: El comando 'vault' no está instalado en este host."
    echo "         Instálalo desde https://developer.hashicorp.com/vault/downloads"
    echo "         o cambia MODO_CONEXION=\"oc-exec\" si ambas instancias están en el mismo cluster."
    exit 1
  fi
  echo "  vault CLI encontrado: $(vault version 2>/dev/null | head -1)"
  echo ""

  for LABEL in ORIGEN DESTINO; do
    if [ "${LABEL}" = "ORIGEN" ]; then
      ADDR="${ADDR_ORIGEN}"; TOK="${TOKEN_ORIGEN}"
    else
      ADDR="${ADDR_DESTINO}"; TOK="${TOKEN_DESTINO}"
    fi
    echo "  Verificando ${LABEL}: ${ADDR} ..."
    SEALED=$(VAULT_ADDR="${ADDR}" VAULT_SKIP_VERIFY=true \
      vault status -format=json 2>/dev/null | grep '"sealed"' | grep -o 'true\|false' || echo "unreachable")
    if [ "${SEALED}" = "true" ]; then
      echo "  ERROR: Vault ${LABEL} está SEALED."; exit 1
    elif [ "${SEALED}" = "unreachable" ]; then
      echo "  ERROR: No se puede conectar al Vault ${LABEL} en ${ADDR}."; exit 1
    fi
    TOKEN_VALID=$(VAULT_ADDR="${ADDR}" VAULT_TOKEN="${TOK}" VAULT_SKIP_VERIFY=true \
      vault token lookup 2>/dev/null | grep "policies" || echo "INVALID")
    if echo "${TOKEN_VALID}" | grep -qi "INVALID\|error"; then
      echo "  ERROR: Token ${LABEL} inválido o expirado."; exit 1
    fi
    echo "  ${LABEL} OK — Sealed: ${SEALED}, token válido."
  done
else
  for LABEL in ORIGEN DESTINO; do
    if [ "${LABEL}" = "ORIGEN" ]; then
      POD="${POD_ORIGEN}"; NS="${NS_ORIGEN}"; TOK="${TOKEN_ORIGEN}"
    else
      POD="${POD_DESTINO}"; NS="${NS_DESTINO}"; TOK="${TOKEN_DESTINO}"
    fi
    echo "  Verificando ${LABEL}: ${POD} (ns: ${NS})..."
    SEALED=$(oc exec "${POD}" -n "${NS}" -- \
      vault status -tls-skip-verify 2>/dev/null | grep "^Sealed" | awk '{print $2}' || echo "unreachable") || true
    if [ "${SEALED}" = "true" ]; then
      echo "  ERROR: Vault ${LABEL} está SEALED."; exit 1
    elif [ "${SEALED}" = "unreachable" ]; then
      echo "  ERROR: No se puede conectar al Vault ${LABEL}."; exit 1
    fi
    TOKEN_VALID=$(printf 'vault login -tls-skip-verify %s 2>/dev/null | grep token_policies || echo INVALID\n' "${TOK}" \
      | oc exec -i "${POD}" -n "${NS}" -- sh 2>/dev/null || echo "INVALID")
    if echo "${TOKEN_VALID}" | grep -qi "INVALID\|error"; then
      echo "  ERROR: Token ${LABEL} inválido."; exit 1
    fi
    echo "  ${LABEL} OK — Sealed: ${SEALED}, token válido."
  done
fi

migrar_kv() {
  print_step "MIGRANDO KV-V2 (secret/)"

  habilitar_engine_destino "secret" "kv" "-options=version=2"

  _migrar_kv_prefijo() {
    local prefijo="$1"
    local items
    items=$(exec_origen "vault kv list -tls-skip-verify -format=json '${ENGINE_ORIGEN:-secret}/${prefijo}' 2>/dev/null \
      | grep -o '\"[^\"]*\"' | sed 's/\"//g'")
    [ -z "${items}" ] && return

    while IFS= read -r item; do
      [ -z "${item}" ] && continue
      if echo "${item}" | grep -q '/$'; then
        _migrar_kv_prefijo "${prefijo}${item}"
      else
        local path="${prefijo}${item}"
        echo ""
        echo "  → kv: secret/${path}"

        local JSON
        JSON=$(exec_origen "vault kv get -tls-skip-verify -format=json 'secret/${path}' 2>/dev/null")
        if [ -z "${JSON}" ]; then
          echo "    ⚠  No se pudo leer. Omitiendo."; TOTAL_SKIP=$((TOTAL_SKIP+1)); continue
        fi

        # Extraer .data.data: segundo bloque "data": { del JSON kv-v2
        local KV_PAIRS
        KV_PAIRS=$(echo "${JSON}" | awk '
          BEGIN { dc=0; in_data=0; r="" }
          /"data"[[:space:]]*:[[:space:]]*\{/ { dc++; if(dc==2){ in_data=1; next } }
          in_data==1 && /"[^"]+"[[:space:]]*:[[:space:]]*"[^"]*"/ {
            k=$0; v=$0
            gsub(/^[[:space:]]*"/,"",k); gsub(/"[[:space:]]*:.*/,"",k)
            gsub(/^[^:]*:[[:space:]]*"/,"",v); gsub(/"[[:space:]]*,?[[:space:]]*$/,"",v)
            r=r k "=\"" v "\" "
          }
          in_data==1 && /^[[:space:]]*\}[[:space:]]*,?[[:space:]]*$/ { in_data=0 }
          END { if(r=="") print "EMPTY"; else print r }
        ')

        # Normalizar escapes unicode
        KV_PAIRS=$(echo "${KV_PAIRS}" | sed 's/\\u0026/\&/g;s/\\u003d/=/g;s/\\u003c/</g;s/\\u003e/>/g')

        if [ "${KV_PAIRS}" = "EMPTY" ] || [ -z "${KV_PAIRS}" ]; then
          echo "    ⚠  Sin claves string extraíbles. Omitiendo."; TOTAL_SKIP=$((TOTAL_SKIP+1)); continue
        fi

        local NC
        NC=$(echo "${KV_PAIRS}" | grep -o '="' | wc -l | tr -d ' ')
        local NAMES
        NAMES=$(echo "${KV_PAIRS}" | grep -o '[^ =]*="' | sed 's/="//g' | tr '\n' ' ')
        echo "    Claves (${NC}): ${NAMES}"

        if [ "${DRY_RUN}" = "true" ]; then
          echo "    [DRY-RUN] vault kv put secret/${path} ${KV_PAIRS}"
          TOTAL_OK=$((TOTAL_OK+1)); continue
        fi

        local R
        R=$(exec_destino_kv_put "${path}" "${KV_PAIRS}")
        if echo "${R}" | grep -qi "error\|permission denied"; then
          echo "    ✗ Error: ${R}"; TOTAL_ERR=$((TOTAL_ERR+1))
        else
          echo "    ✓ OK"; TOTAL_OK=$((TOTAL_OK+1))
        fi
      fi
    done <<< "${items}"
  }

  _migrar_kv_prefijo ""
}

# Migra: CA root y roles de emisión.
# Los certificados individuales NO se migran — son efímeros, deben reemitirse.
migrar_pki() {
  print_step "MIGRANDO PKI (pki/)"

  habilitar_engine_destino "pki" "pki" "-max-lease-ttl=315360000"

  echo ""
  echo "  → pki: CA root (issuer)"
  local CA_PEM
  CA_PEM=$(exec_origen "vault read -tls-skip-verify -field=certificate pki/cert/ca 2>/dev/null")
  local CA_KEY
  CA_KEY=$(exec_origen "vault read -tls-skip-verify pki/export-key-backup 2>/dev/null | grep 'private_key ' | awk '{print \$2}'" 2>/dev/null || true)

  if [ -n "${CA_PEM}" ]; then
    if [ "${DRY_RUN}" = "true" ]; then
      echo "    [DRY-RUN] importar CA root en pki/"
    else
      # Sin clave privada exportable: genera nueva CA en DESTINO con mismo CN.
      local ISSUER_CN
      ISSUER_CN=$(exec_origen "vault read -tls-skip-verify pki/cert/ca 2>/dev/null \
        | grep 'issuing_ca' | head -1 | awk '{print \$2}'")
      local R
      R=$(exec_destino "vault write -tls-skip-verify pki/root/generate/internal \
        common_name='${ISSUER_CN:-VaultCA-Migrado}' ttl=315360000 2>&1 | head -1")
      if echo "${R}" | grep -qi "error"; then
        echo "    ⚠  CA ya configurada o error: ${R}"; TOTAL_SKIP=$((TOTAL_SKIP+1))
      else
        echo "    ✓ CA generada en DESTINO (nueva CA — los certificados deben reemitirse)"; TOTAL_OK=$((TOTAL_OK+1))
      fi
    fi
  else
    echo "    ⚠  No se pudo leer la CA del ORIGEN."; TOTAL_SKIP=$((TOTAL_SKIP+1))
  fi

  echo ""
  echo "  → pki: roles de emisión"
  local ROLES
  ROLES=$(exec_origen "vault list -tls-skip-verify -format=json pki/roles 2>/dev/null \
    | grep -o '\"[^\"]*\"' | sed 's/\"//g'")

  if [ -n "${ROLES}" ]; then
    while IFS= read -r role; do
      [ -z "${role}" ] && continue
      echo "    Rol: ${role}"
      local ROLE_DATA
      ROLE_DATA=$(exec_origen "vault read -tls-skip-verify -format=json pki/roles/${role} 2>/dev/null")
      if [ -z "${ROLE_DATA}" ]; then
        echo "    ⚠  No se pudo leer el rol '${role}'."; TOTAL_SKIP=$((TOTAL_SKIP+1)); continue
      fi

      local ALLOWED_DOMAINS TTL MAX_TTL KEY_TYPE
      ALLOWED_DOMAINS=$(echo "${ROLE_DATA}" | grep '"allowed_domains"' | grep -o '"[^"]*"' | tail -1 | sed 's/"//g')
      TTL=$(echo "${ROLE_DATA}" | grep '"ttl"' | head -1 | grep -o '[0-9]*' | head -1)
      MAX_TTL=$(echo "${ROLE_DATA}" | grep '"max_ttl"' | head -1 | grep -o '[0-9]*' | head -1)
      KEY_TYPE=$(echo "${ROLE_DATA}" | grep '"key_type"' | grep -o '"[^"]*"' | tail -1 | sed 's/"//g')

      if [ "${DRY_RUN}" = "true" ]; then
        echo "    [DRY-RUN] vault write pki/roles/${role} allowed_domains=${ALLOWED_DOMAINS} ..."
        TOTAL_OK=$((TOTAL_OK+1)); continue
      fi

      local R
      R=$(exec_destino "vault write -tls-skip-verify pki/roles/${role} \
        allowed_domains='${ALLOWED_DOMAINS}' \
        allow_subdomains=true \
        allow_bare_domains=true \
        ttl='${TTL:-720h}' \
        max_ttl='${MAX_TTL:-8760h}' \
        key_type='${KEY_TYPE:-rsa}' 2>&1 | head -1")
      if echo "${R}" | grep -qi "error"; then
        echo "    ✗ Error en rol '${role}': ${R}"; TOTAL_ERR=$((TOTAL_ERR+1))
      else
        echo "    ✓ Rol '${role}' migrado"; TOTAL_OK=$((TOTAL_OK+1))
      fi
    done <<< "${ROLES}"
  else
    echo "    (sin roles definidos)"
  fi

  echo ""
  echo "  ⚠  NOTA: Los certificados individuales NO se migran — son efímeros."
  echo "     Las aplicaciones deben solicitar nuevos certificados al DESTINO."
}

# Si la clave tiene allow_plaintext_backup: exporta y restaura (preserva material).
# Si no: crea nueva clave del mismo tipo. ⚠ Datos cifrados con ORIGEN no son
# descifrables con la nueva clave DESTINO.
migrar_transit() {
  print_step "MIGRANDO TRANSIT (transit/)"

  habilitar_engine_destino "transit" "transit" ""

  local KEYS
  KEYS=$(exec_origen "vault list -tls-skip-verify -format=json transit/keys 2>/dev/null \
    | grep -o '\"[^\"]*\"' | sed 's/\"//g'")

  if [ -z "${KEYS}" ]; then
    echo "  (sin claves transit)"; return
  fi

  while IFS= read -r key; do
    [ -z "${key}" ] && continue
    echo ""
    echo "  → transit: clave '${key}'"

    local KEY_DATA
    KEY_DATA=$(exec_origen "vault read -tls-skip-verify -format=json transit/keys/${key} 2>/dev/null")
    local KEY_TYPE EXPORTABLE ALLOW_PLAINTEXT_BACKUP
    KEY_TYPE=$(echo "${KEY_DATA}" | grep '"type"' | grep -o '"[^"]*"' | tail -1 | sed 's/"//g')
    EXPORTABLE=$(echo "${KEY_DATA}" | grep '"exportable"' | grep -o 'true\|false' | head -1)
    ALLOW_PLAINTEXT_BACKUP=$(echo "${KEY_DATA}" | grep '"allow_plaintext_backup"' | grep -o 'true\|false' | head -1)

    echo "    Tipo: ${KEY_TYPE:-aes256-gcm96}  |  Exportable: ${EXPORTABLE:-false}"

    if [ "${DRY_RUN}" = "true" ]; then
      echo "    [DRY-RUN] vault write transit/keys/${key} type=${KEY_TYPE}"
      TOTAL_OK=$((TOTAL_OK+1)); continue
    fi

    if [ "${ALLOW_PLAINTEXT_BACKUP}" = "true" ]; then
      local BACKUP
      BACKUP=$(exec_origen "vault read -tls-skip-verify -field=backup transit/backup/${key} 2>/dev/null")
      if [ -n "${BACKUP}" ]; then
        local R
        R=$(exec_destino "vault write -tls-skip-verify transit/restore/${key} backup='${BACKUP}' 2>&1 | head -1")
        if echo "${R}" | grep -qi "error"; then
          echo "    ✗ Error en restore: ${R}"; TOTAL_ERR=$((TOTAL_ERR+1))
        else
          echo "    ✓ Clave '${key}' restaurada desde backup (material de clave preservado)"; TOTAL_OK=$((TOTAL_OK+1))
        fi
        continue
      fi
    fi

    local R
    R=$(exec_destino "vault write -tls-skip-verify -f transit/keys/${key} type='${KEY_TYPE:-aes256-gcm96}' 2>&1 | head -1")
    if echo "${R}" | grep -qi "error"; then
      echo "    ✗ Error creando clave: ${R}"; TOTAL_ERR=$((TOTAL_ERR+1))
    else
      echo "    ✓ Clave '${key}' creada (NUEVA — datos cifrados con ORIGEN no son descifrable con DESTINO)"; TOTAL_OK=$((TOTAL_OK+1))
    fi
  done <<< "${KEYS}"
}

# La password de conexión NO se puede exportar de Vault — debe reingresarse.
migrar_database() {
  print_step "MIGRANDO DATABASE (database/)"

  habilitar_engine_destino "database" "database" ""

  echo ""
  echo "  → database: conexiones"
  local CONFIGS
  CONFIGS=$(exec_origen "vault list -tls-skip-verify -format=json database/config 2>/dev/null \
    | grep -o '\"[^\"]*\"' | sed 's/\"//g'")

  if [ -n "${CONFIGS}" ]; then
    while IFS= read -r cfg; do
      [ -z "${cfg}" ] && continue
      echo "    Conexión: ${cfg}"
      local CFG_DATA
      CFG_DATA=$(exec_origen "vault read -tls-skip-verify -format=json database/config/${cfg} 2>/dev/null")

      local PLUGIN_NAME CONN_URL
      PLUGIN_NAME=$(echo "${CFG_DATA}" | grep '"plugin_name"' | grep -o '"[^"]*"' | tail -1 | sed 's/"//g')
      CONN_URL=$(echo "${CFG_DATA}" | grep '"connection_details"' -A5 | grep '"connection_url"' \
        | grep -o '"[^"]*"' | tail -1 | sed 's/"//g')

      echo "    Plugin: ${PLUGIN_NAME}  |  URL: ${CONN_URL}"
      echo "    ⚠  La password de conexión NO se exporta — debes reconfigurarla manualmente:"
      echo "       vault write database/config/${cfg} plugin_name=${PLUGIN_NAME} \\"
      echo "         connection_url=\"${CONN_URL}\" username=<USER> password=<PASS>"
      TOTAL_SKIP=$((TOTAL_SKIP+1))
    done <<< "${CONFIGS}"
  fi

  echo ""
  echo "  → database: roles dinámicos"
  local ROLES
  ROLES=$(exec_origen "vault list -tls-skip-verify -format=json database/roles 2>/dev/null \
    | grep -o '\"[^\"]*\"' | sed 's/\"//g'")

  if [ -n "${ROLES}" ]; then
    while IFS= read -r role; do
      [ -z "${role}" ] && continue
      echo "    Rol: ${role}"
      local ROLE_DATA
      ROLE_DATA=$(exec_origen "vault read -tls-skip-verify -format=json database/roles/${role} 2>/dev/null")

      local DB_NAME CREATION_STMT DEFAULT_TTL MAX_TTL
      DB_NAME=$(echo "${ROLE_DATA}" | grep '"db_name"' | grep -o '"[^"]*"' | tail -1 | sed 's/"//g')
      DEFAULT_TTL=$(echo "${ROLE_DATA}" | grep '"default_ttl"' | grep -o '[0-9]*' | head -1)
      MAX_TTL=$(echo "${ROLE_DATA}" | grep '"max_ttl"' | grep -o '[0-9]*' | head -1)
      CREATION_STMT=$(echo "${ROLE_DATA}" | grep '"creation_statements"' -A3 | grep -o '"[^"]*"' | grep -v 'creation_statements' | head -1 | sed 's/"//g')

      if [ "${DRY_RUN}" = "true" ]; then
        echo "    [DRY-RUN] vault write database/roles/${role} db_name=${DB_NAME} ..."
        TOTAL_OK=$((TOTAL_OK+1)); continue
      fi

      local R
      R=$(exec_destino "vault write -tls-skip-verify database/roles/${role} \
        db_name='${DB_NAME}' \
        creation_statements='${CREATION_STMT}' \
        default_ttl='${DEFAULT_TTL:-1h}' \
        max_ttl='${MAX_TTL:-24h}' 2>&1 | head -1")
      if echo "${R}" | grep -qi "error"; then
        echo "    ✗ Error en rol '${role}': ${R}"; TOTAL_ERR=$((TOTAL_ERR+1))
      else
        echo "    ✓ Rol '${role}' migrado"; TOTAL_OK=$((TOTAL_OK+1))
      fi
    done <<< "${ROLES}"
  fi
}

print_step "INVENTARIO DEL VAULT ORIGEN"

echo ""
echo "  Engines activos en ORIGEN:"
exec_origen "vault secrets list -tls-skip-verify 2>/dev/null | grep -v '^Path\|^----' || true" | \
  while read -r line; do echo "    ${line}"; done || true

echo ""
echo "  Engines configurados para migrar:"
[ "${MIGRAR_KV}"       = "true" ] && echo "    ✅ kv-v2     (secret/)"
[ "${MIGRAR_PKI}"      = "true" ] && echo "    ✅ pki       (pki/)"
[ "${MIGRAR_TRANSIT}"  = "true" ] && echo "    ✅ transit   (transit/)"
[ "${MIGRAR_DATABASE}" = "true" ] && echo "    ✅ database  (database/)"
echo "    ⛔ cubbyhole  — no migrable (privado por token)"
echo "    ⛔ identity   — no migrable (interno Vault)"
echo "    ⛔ sys        — no migrable (interno Vault)"
echo ""
echo "  DRY-RUN: ${DRY_RUN}"

[ "${MIGRAR_KV}"       = "true" ] && migrar_kv       || true
[ "${MIGRAR_PKI}"      = "true" ] && migrar_pki      || true
[ "${MIGRAR_TRANSIT}"  = "true" ] && migrar_transit  || true
[ "${MIGRAR_DATABASE}" = "true" ] && migrar_database || true

print_step "VERIFICACIÓN — ESTADO DEL DESTINO LUEGO DE LA 'MIGRACIÓN'"

echo ""
echo "  Engines en DESTINO:"
exec_destino "vault secrets list -tls-skip-verify 2>/dev/null | grep -v '^Path\|^----' || true" | \
  while read -r line; do echo "    ${line}"; done || true

echo ""
echo "  Secrets kv-v2 en DESTINO (secret/):"
exec_destino "vault kv list -tls-skip-verify secret/ 2>/dev/null || true" | \
  while read -r line; do echo "    ${line}"; done || echo "    (vacío)"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║              MIGRACIÓN COMPLETADA                                    ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
if [ "${MODO_CONEXION}" = "vault-cli" ]; then
  echo "  _ ORIGEN  : ${ADDR_ORIGEN}"
  echo "  _ DESTINO : ${ADDR_DESTINO}"
else
  echo "  _ ORIGEN  : ${POD_ORIGEN} - ns: ${NS_ORIGEN}"
  echo "  _ DESTINO : ${POD_DESTINO} - ns: ${NS_DESTINO}"
fi
echo "  _ MODO    : ${MODO_CONEXION}"
echo ""
echo "  ┌─ RESULTADOS ──────────────────────────────────────────────────────┐"
echo "  │  ✓ Migrados correctamente : ${TOTAL_OK}"
echo "  │  ⚠  Omitidos / Manuales  : ${TOTAL_SKIP}"
echo "  │  ✗ Errores                : ${TOTAL_ERR}"
echo "  └───────────────────────────────────────────────────────────────────┘"
echo ""
if [ "${TOTAL_SKIP}" -gt 0 ]; then
  echo "  ⚠  Items omitidos requieren acción manual (ver detalle arriba)."
  echo "     Principalmente: passwords de conexiones database/"
fi
echo ""
echo "  PRÓXIMOS PASOS:"
echo "  1. Verificar un secreto kv migrado:"
echo "     oc exec ${POD_DESTINO} -n ${NS_DESTINO} -- vault kv get -tls-skip-verify secret/secret_ibm_01"
echo "  2. Para sincronizar con APPs JAVA via VSO, crear VaultStaticSecret" 
echo ""
echo "╚══════════════════════════════════════════════════════════════════════╝"
