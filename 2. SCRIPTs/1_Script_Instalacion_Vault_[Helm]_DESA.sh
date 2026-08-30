#!/bin/bash

# =============================================================================
# INSTALACIÓN / DESINSTALACIÓN - VAULT DEV (DESARROLLO) - [HELM]
# =============================================================================
# INSTALA o ELIMINA Vault en modo DEV (single-pod, sin TLS, sin HA, sin PVC) en OPENSHIFT. 
# Ideal para pruebas. Los datos NO son PERSISTENTES: se pierden al reiniciar el POD.
#
# DIFERENCIAS respecto al script de PRODUCCIÓN:
#   - server.dev.enabled=true  → modo dev: token root fijo "root", sin unseal
#   - Sin TLS / Sin HA         → un solo pod, HTTP en el puerto 8200
#   - Sin PVC                  → almacenamiento en memoria
#   - Route HTTP (edge)        → sin certificado propio
#
# CARACTERÍSTICAS:
#   _ RÉPLICAS  : 1 (single-pod, sin HA)
#   _ CPU       : request 100m  / limit 250m
#   _ MEMORIA   : request 128Mi / limit 256Mi
#   _ STORAGE   : ninguno — almacenamiento en memoria (datos NO persistentes)
#   _ TLS       : deshabilitado — HTTP puerto 8200
#   _ SEGURIDAD : root token fijo "root", sin unseal, sin audit log
#   _ ROUTE     : HTTP edge (router OCP)
#   _ EXTRAS    : Agent Injector habilitado
#
# PRERREQUISITOS:
#   1. NAMESPACE "${NAMESPACE}" existente: $ oc create namespace ${NAMESPACE}
#   2. IBM ENTITLEMENT-KEY aplicado en el NAMESPACE "${NAMESPACE}" antes de este SCRIPT:
#      $ oc create secret docker-registry ibm-entitlement-key \
#          --docker-server=cp.icr.io --docker-username=cp \
#          --docker-password=<ENTITLEMENT_KEY> -n ${NAMESPACE}
#   3. Autenticación en OPENSHIFT activa: $ oc login ...
#
# REQUERIMIENTOS DE INFRAESTRUCTURA:
#   _ CPU     : 1 nodo con al menos 100m disponibles (request) / 250m (limit)
#   _ MEMORIA : 1 nodo con al menos 128Mi disponibles (request) / 256Mi (limit)
#   _ STORAGE : ninguno — datos en memoria (no persistentes)
#   _ NODOS   : 1 worker con capacidad para scheduling del pod vault-0
#
# USO:
#   $ sh ./1_Script_Instalacion_Vault_[Helm]_DESA.sh --modalidad=install
#   $ sh ./1_Script_Instalacion_Vault_[Helm]_DESA.sh --modalidad=delete
# =============================================================================

set -e
set -o pipefail

# Limpiar variables Vault heredadas de Windows para evitar que MSYS2
# convierta paths Unix en rutas Windows al pasarlos a oc exec.
unset VAULT_CACERT VAULT_TLSCERT VAULT_TLSKEY VAULT_ADDR VAULT_TOKEN VAULT_NAMESPACE

MODALIDAD=""

for ARG in "$@"; do
  case "${ARG}" in
    --modalidad=install)
      MODALIDAD="install"
      ;;
    --modalidad=delete)
      MODALIDAD="delete"
      ;;
    --modalidad=*)
      echo "ERROR: Modalidad desconocida '${ARG}'."
      echo "       Usa: --modalidad=install  o  --modalidad=delete"
      exit 1
      ;;
    *)
      echo "ERROR: Argumento desconocido '${ARG}'."
      echo "       Uso: sh ./1_Script_Instalacion_Vault_[Helm]_DESA.sh --modalidad=install|delete"
      exit 1
      ;;
  esac
done

if [ -z "${MODALIDAD}" ]; then
  echo "ERROR: Debes indicar la modalidad de ejecución."
  echo ""
  echo "  Uso:"
  echo "    sh ./1_Script_Instalacion_Vault_[Helm]_DESA.sh --modalidad=install"
  echo "    sh ./1_Script_Instalacion_Vault_[Helm]_DESA.sh --modalidad=delete"
  echo ""
  exit 1
fi

# --- Parámetros ---
NAMESPACE="vault"

HELM_REPO_NAME="hashicorp"
HELM_REPO_URL="https://helm.releases.hashicorp.com"
RELEASE_NAME="vault"

VAULT_IMAGE_REPOSITORY="registry.connect.redhat.com/hashicorp/vault"
VAULT_IMAGE_TAG="1.21.2-ubi"

VAULT_K8S_IMAGE_REPOSITORY="registry.connect.redhat.com/hashicorp/vault-k8s"
VAULT_K8S_IMAGE_TAG="1.7.2-ubi"

VAULT_SERVICE_UI="${RELEASE_NAME}-ui"
VAULT_POD="${RELEASE_NAME}-0"

VAULT_CPU_REQUEST="100m"
VAULT_CPU_LIMIT="250m"
VAULT_MEM_REQUEST="128Mi"
VAULT_MEM_LIMIT="256Mi"

INJECTOR_CPU_REQUEST="50m"
INJECTOR_CPU_LIMIT="100m"
INJECTOR_MEM_REQUEST="64Mi"
INJECTOR_MEM_LIMIT="128Mi"

# En modo dev el root token es siempre "root" (hardcoded por Vault)
DEV_ROOT_TOKEN="root"

# --- Utilidades ---
print_step() {
  echo ""
  echo "Sentencia ejecutada:"
  echo "$1"
  echo ""
}

run_cmd() {
  print_step "$*"
  "$@"
}

run_cmd_allow_error() {
  print_step "$*"
  "$@" || true
}

modalidad_delete() {
  echo ""
  echo "==========================================================================="
  echo "  [INICIO DE ELIMINACIÓN - DESARROLLO]  namespace: ${NAMESPACE}"
  echo "==========================================================================="
  echo ""

  echo "===> D.1. Eliminando Helm release '${RELEASE_NAME}'..."
  if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}"
    echo "     Release eliminado. Esperando 10s para que los pods terminen..."
    sleep 10
  else
    echo "     No existe release. Omitiendo."
  fi

  echo "===> D.2. Eliminando Route '${RELEASE_NAME}-ui'..."
  if oc get route "${RELEASE_NAME}-ui" -n "${NAMESPACE}" &>/dev/null; then
    oc delete route "${RELEASE_NAME}-ui" -n "${NAMESPACE}"
    echo "     Route eliminada."
  else
    echo "     No existe. Omitiendo."
  fi

  echo "===> D.4. Eliminando recursos RBAC residuales..."
  oc delete serviceaccount "${RELEASE_NAME}" -n "${NAMESPACE}" 2>/dev/null || true
  oc delete serviceaccount "${RELEASE_NAME}-agent-injector" -n "${NAMESPACE}" 2>/dev/null || true
  oc delete clusterrolebinding "${RELEASE_NAME}-server-binding" 2>/dev/null || true
  oc delete clusterrolebinding "${RELEASE_NAME}-agent-injector-binding" 2>/dev/null || true
  oc delete clusterrole "${RELEASE_NAME}-agent-injector-clusterrole" 2>/dev/null || true
  oc delete mutatingwebhookconfiguration "${RELEASE_NAME}-agent-injector-cfg" 2>/dev/null || true

  echo "===> D.5. El namespace '${NAMESPACE}' NO es eliminado por este script (prerrequisito externo)."

  echo ""
  echo "==========================================================================="
  echo "  [FIN DE ELIMINACIÓN]  Vault ha sido desinstalado del namespace '${NAMESPACE}'."
  echo "==========================================================================="
  echo ""
}

modalidad_install() {
  echo ""
  echo "==========================================================================="
  echo "  [INICIO DE INSTALACIÓN - DESARROLLO]  namespace: ${NAMESPACE}"
  echo "==========================================================================="
  echo ""

  echo "===> 0. LIMPIEZA DE INSTALACIÓN PREVIA (si existe)"

  echo "  --> Helm release '${RELEASE_NAME}'..."
  if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}"
    echo "      Release eliminado."
    echo "      Esperando 10s para que los pods terminen..."
    sleep 10
  else
    echo "      No existe. Omitiendo."
  fi

  echo "  --> Route '${RELEASE_NAME}-ui'..."
  if oc get route "${RELEASE_NAME}-ui" -n "${NAMESPACE}" &>/dev/null; then
    oc delete route "${RELEASE_NAME}-ui" -n "${NAMESPACE}"
    echo "      Route eliminada."
  else
    echo "      No existe. Omitiendo."
  fi

  echo "  Limpieza completada."
  echo ""

  echo "===> 1. VERIFICANDO IBM ENTITLEMENT KEY (prerrequisito)"
  if ! oc get secret "ibm-entitlement-key" -n "${NAMESPACE}" &>/dev/null; then
    echo "ERROR: El secret 'ibm-entitlement-key' no existe en el namespace '${NAMESPACE}'."
    echo "       Créalo antes de ejecutar este script (ver PRERREQUISITOS en el encabezado)."
    exit 1
  fi
  echo "     Secret 'ibm-entitlement-key' encontrado. Continuando..."

  echo "===> 2. AGREGANDO REPOSITORIO HELM DE HASHICORP"
  helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" 2>/dev/null || true

  echo "===> 4. ACTUALIZANDO REPOSITORIO HELM"
  helm repo update

  # MSYS_NO_PATHCONV=1 evita que MSYS2 convierta paths en argumentos --set.
  # server.dev.enabled=true → root token "root", almacenamiento en memoria, sin unseal.
  # server.dataStorage.enabled=false → sin PVC. No usar en producción.
  echo "===> 5. INSTALANDO VAULT EN MODO DEV"

  MSYS_NO_PATHCONV=1 helm install "${RELEASE_NAME}" "${HELM_REPO_NAME}/vault" \
    -n "${NAMESPACE}" \
    \
    --set global.openshift=true \
    \
    --set server.dev.enabled=true \
    \
    --set server.image.repository="${VAULT_IMAGE_REPOSITORY}" \
    --set server.image.tag="${VAULT_IMAGE_TAG}" \
    \
    --set server.resources.requests.cpu="${VAULT_CPU_REQUEST}" \
    --set server.resources.requests.memory="${VAULT_MEM_REQUEST}" \
    --set server.resources.limits.cpu="${VAULT_CPU_LIMIT}" \
    --set server.resources.limits.memory="${VAULT_MEM_LIMIT}" \
    \
    --set server.ha.enabled=false \
    \
    --set server.dataStorage.enabled=false \
    --set server.auditStorage.enabled=false \
    \
    --set injector.enabled=true \
    --set injector.image.repository="${VAULT_K8S_IMAGE_REPOSITORY}" \
    --set injector.image.tag="${VAULT_K8S_IMAGE_TAG}" \
    --set injector.agentImage.repository="${VAULT_IMAGE_REPOSITORY}" \
    --set injector.agentImage.tag="${VAULT_IMAGE_TAG}" \
    --set injector.resources.requests.cpu="${INJECTOR_CPU_REQUEST}" \
    --set injector.resources.requests.memory="${INJECTOR_MEM_REQUEST}" \
    --set injector.resources.limits.cpu="${INJECTOR_CPU_LIMIT}" \
    --set injector.resources.limits.memory="${INJECTOR_MEM_LIMIT}" \
    \
    --set ui.enabled=true

  echo "===> 6. VALIDANDO ESTADO DEL RELEASE HELM"
  helm status "${RELEASE_NAME}" -n "${NAMESPACE}"

  # En modo dev Vault arranca inicializado y desbloqueado (~15-30s).
  echo "===> 7. ESPERANDO QUE EL POD ESTÉ LISTO (timeout 3 min)"
  run_cmd_allow_error oc wait pod \
    -l app.kubernetes.io/name=vault \
    -n "${NAMESPACE}" \
    --for=condition=Ready \
    --timeout=180s

  echo "===> 8. RECURSOS DESPLEGADOS (pods, servicios)"
  oc get pods,svc -n "${NAMESPACE}"

  echo "===> 9. EXPONIENDO LA UI DE VAULT (Route HTTP)"

  UI_SVC_WAIT=0
  until oc get service "${VAULT_SERVICE_UI}" -n "${NAMESPACE}" &>/dev/null; do
    if [ "${UI_SVC_WAIT}" -ge 60 ]; then
      echo "  ADVERTENCIA: Service '${VAULT_SERVICE_UI}' no encontrado tras 60s. Continuando..."
      break
    fi
    sleep 5
    UI_SVC_WAIT=$((UI_SVC_WAIT + 5))
  done

  EXISTING_ROUTE=$(oc get route "${RELEASE_NAME}-ui" -n "${NAMESPACE}" \
    -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

  if [ -z "${EXISTING_ROUTE}" ]; then
    oc expose service "${VAULT_SERVICE_UI}" \
      --name="${RELEASE_NAME}-ui" \
      -n "${NAMESPACE}" || true
    echo "  Route HTTP creada."
  else
    echo "  Route ya existe, sin cambios."
  fi

  echo "===> 10. ROUTES DEL NAMESPACE"
  oc get route -n "${NAMESPACE}"

  VAULT_ROUTE=$(oc get route "${RELEASE_NAME}-ui" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.host}' 2>/dev/null || echo "N/A")
  VAULT_HEALTH=$(curl -s --max-time 5 "http://${VAULT_ROUTE}/v1/sys/health" \
    | python -c "import sys,json; d=json.loads(sys.stdin.read()); \
      print('initialized='+str(d.get('initialized')),'sealed='+str(d.get('sealed')))" \
    2>/dev/null || echo "no_response")

  echo ""
  echo "=========================================================================="
  echo "  INSTALACIÓN DE VAULT DEV (DESARROLLO) - RESUMEN"
  echo "=========================================================================="
  echo "  NAMESPACE           : ${NAMESPACE}"
  echo "  MODO                : DEV (single-node, in-memory, sin TLS)"
  echo "  RÉPLICAS            : 1"
  echo "  ALMACENAMIENTO      : En memoria (datos NO persistentes)"
  echo "  UI URL              : http://${VAULT_ROUTE}/ui"
  echo "  UI HEALTH CHECK     : ${VAULT_HEALTH}"
  echo "  ROOT TOKEN (login)  : ${DEV_ROOT_TOKEN}"
  echo "=========================================================================="
  echo ""
  echo "  PRÓXIMOS PASOS RECOMENDADOS:"
  echo "  1. Acceder a la UI: http://${VAULT_ROUTE}/ui"
  echo "     → Método: Token   |   Token: ${DEV_ROOT_TOKEN}"
  echo "  2. Habilitar un motor de secretos (ej: kv-v2):"
  echo "       vault secrets enable -path=secret kv-v2"
  echo "  3. Para un entorno persistente, usar el script de PRODUCCIÓN."
  echo "  ADVERTENCIA: Los datos se pierden al reiniciar el pod vault-0."
  echo "=========================================================================="
  echo ""
  echo "----------------------------- [TÉRMINO DE INSTALACIÓN - DESARROLLO] -----------------------------"
}

case "${MODALIDAD}" in
  install)
    modalidad_install
    ;;
  delete)
    modalidad_delete
    ;;
esac
