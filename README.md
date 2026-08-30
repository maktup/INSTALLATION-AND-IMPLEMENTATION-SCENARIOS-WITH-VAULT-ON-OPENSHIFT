# IBM VAULT: GUÍA DE ESCENARIOS DE INSTALACIÓN EN RED HAT OPENSHIFT

> Comparativa técnica de cuatro escenarios de despliegue de HashiCorp / IBM Vault sobre Red Hat OpenShift mediante **Helm Chart** y **OpenShift Operator**, para ambientes de **desarrollo** y **producción**.

---

# CONTEXTO

IBM Vault permite administrar secretos, credenciales, certificados y material criptográfico de forma centralizada. En Red Hat OpenShift puede desplegarse mediante Helm o integrarse con recursos nativos del clúster mediante Vault Secrets Operator (VSO).

Esta guía presenta cuatro alternativas de instalación:

1. Helm para desarrollo.
2. Helm para producción.
3. OpenShift Operator para desarrollo.
4. OpenShift Operator para producción.

Cada escenario describe su arquitectura, recursos, almacenamiento, seguridad, prerrequisitos y comandos de instalación o eliminación.

# OBJETIVO

El objetivo es facilitar la selección del modelo de despliegue más adecuado de acuerdo con:

- Tipo de ambiente: desarrollo o producción.
- Requerimientos de alta disponibilidad.
- Configuración TLS.
- Persistencia de datos y auditoría.
- Integración con recursos nativos de OpenShift.
- Capacidad disponible de CPU, memoria, almacenamiento y nodos worker.

# RESUMEN DE ESCENARIOS

| ESCENARIO | MODALIDAD | AMBIENTE | HA | TLS | STORAGE | USO RECOMENDADO |
|---|---|---|---|---|---|---|
| 1 | Helm Chart | Desarrollo | No | HTTP | Sin persistencia | Pruebas rápidas |
| 2 | Helm Chart | Producción | 3 réplicas | HTTPS end-to-end | 45 Gi | Producción administrada con Helm |
| 3 | OpenShift Operator | Desarrollo | No | Edge HTTPS | 2 Gi | Desarrollo nativo en OpenShift |
| 4 | OpenShift Operator | Producción | 3 réplicas | HTTPS end-to-end | 45 Gi | Producción nativa en OpenShift |

---

# ESCENARIO 1: INSTALACIÓN MEDIANTE HELM PARA DESARROLLO

Despliegue de un solo pod en `dev mode`, sin alta disponibilidad ni persistencia.

## CARACTERÍSTICAS

| PARÁMETRO | VALOR |
|---|---|
| Réplicas | 1 pod, sin HA |
| Modo Vault | Dev mode con token root fijo `root` |
| TLS | Deshabilitado; HTTP en el puerto 8200 |
| Unseal | Automático por dev mode |
| Persistencia | Ninguna; datos en memoria |
| Route | HTTP edge mediante el router de OpenShift |
| Agent Injector | Habilitado |
| Audit log | No configurado |

## REQUERIMIENTOS DE INFRAESTRUCTURA

| RECURSO | REQUEST | LIMIT |
|---|---:|---:|
| CPU | 100m | 250m |
| Memoria | 128 Mi | 256 Mi |
| Storage | Sin almacenamiento persistente | - |
| Nodos mínimos | 1 worker | - |

## PRERREQUISITOS

- Namespace `vault` creado.
- IBM Entitlement Key aplicado en el namespace.
- Sesión activa mediante `oc login`.
- Helm CLI instalado.
- Repositorio de HashiCorp agregado a Helm.

```bash
oc create namespace vault
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

## INSTALACIÓN Y ELIMINACIÓN

```bash
sh ./1_Script_Instalacion_Vault_[Helm]_DESA.sh --modalidad=install
sh ./1_Script_Instalacion_Vault_[Helm]_DESA.sh --modalidad=delete
```

> [!WARNING]
> Este escenario no proporciona alta disponibilidad y almacena los datos en memoria. Debe utilizarse únicamente para pruebas o desarrollo.

---

# ESCENARIO 2: INSTALACIÓN MEDIANTE HELM PARA PRODUCCIÓN

Despliegue HA con almacenamiento integrado Raft, tres réplicas, TLS y volúmenes persistentes.

## CARACTERÍSTICAS

| PARÁMETRO | VALOR |
|---|---|
| Réplicas | 3 pods con HA Raft |
| Modo Vault | Server HA |
| TLS | Certificado x509 autofirmado generado con OpenSSL |
| Unseal | 5 claves con threshold de 3 |
| Persistencia | 10 Gi de datos y 5 Gi de auditoría por nodo |
| Route | Passthrough HTTPS; TLS directo al pod |
| Agent Injector | Habilitado |
| PodDisruptionBudget | `maxUnavailable: 1` |

## REQUERIMIENTOS DE INFRAESTRUCTURA

| RECURSO | REQUEST | LIMIT |
|---|---:|---:|
| CPU Vault por nodo, 3 nodos | 250m | 500m |
| Memoria Vault por nodo, 3 nodos | 256 Mi | 512 Mi |
| CPU Injector | 50m | 250m |
| Memoria Injector | 64 Mi | 128 Mi |
| Storage total | 45 Gi | - |
| Nodos mínimos | 3 workers | - |

El almacenamiento total se distribuye de la siguiente forma:

- `3 x 10 Gi` para datos.
- `3 x 5 Gi` para auditoría.

## PRERREQUISITOS

- Namespace `vault` creado.
- IBM Entitlement Key aplicado en el namespace.
- Sesión activa mediante `oc login`.
- Helm CLI instalado y repositorio de HashiCorp agregado.
- StorageClass `ocs-storagecluster-ceph-rbd` disponible.

## INSTALACIÓN Y ELIMINACIÓN

```bash
sh ./1_Script_Instalacion_Vault_[Helm]_PROD.sh --modalidad=install
sh ./1_Script_Instalacion_Vault_[Helm]_PROD.sh --modalidad=delete
```

> [!IMPORTANT]
> Este escenario proporciona alta disponibilidad, persistencia, audit log y cifrado TLS end-to-end.

---

# ESCENARIO 3: INSTALACIÓN MEDIANTE OPENSHIFT OPERATOR PARA DESARROLLO

Despliegue single-node con almacenamiento Raft, PVC mínimo e integración mediante recursos personalizados de OpenShift.

## CARACTERÍSTICAS

| PARÁMETRO | VALOR |
|---|---|
| Réplicas | 1 pod, single-node Raft y sin HA |
| Modo Vault | Server Raft |
| TLS interno | Deshabilitado mediante `tls_disable=true` |
| Route | Edge HTTPS; el router de OpenShift termina TLS |
| Unseal | 1 clave con threshold de 1 |
| Persistencia | 2 Gi para datos |
| VaultConnection | CRD configurado |
| VaultAuth | CRD configurado |
| Audit log PVC | No configurado |
| Credenciales | Secret de Kubernetes con las claves de inicialización |

## REQUERIMIENTOS DE INFRAESTRUCTURA

| RECURSO | REQUEST | LIMIT |
|---|---:|---:|
| CPU | 100m | 250m |
| Memoria | 128 Mi | 256 Mi |
| Storage | 1 PVC de 2 Gi | - |
| Nodos mínimos | 1 worker | - |

## PRERREQUISITOS

- Namespace `vault` creado.
- IBM Entitlement Key aplicado en el namespace.
- Sesión activa mediante `oc login`.
- Vault Secrets Operator instalado para todos los namespaces.
- CRDs `VaultConnection`, `VaultAuth` y `VaultStaticSecret` disponibles.

## INSTALACIÓN Y ELIMINACIÓN

```bash
sh ./1_Script_Instalacion_Vault_[Operator]_DESA.sh --modalidad=install
sh ./1_Script_Instalacion_Vault_[Operator]_DESA.sh --modalidad=delete
```

> [!WARNING]
> Este escenario no proporciona alta disponibilidad ni audit log persistente. Se recomienda únicamente para desarrollo y pruebas.

---

# ESCENARIO 4: INSTALACIÓN MEDIANTE OPENSHIFT OPERATOR PARA PRODUCCIÓN

Despliegue HA administrado mediante Operator, con almacenamiento Raft, tres réplicas, TLS y autenticación de Kubernetes.

## CARACTERÍSTICAS

| PARÁMETRO | VALOR |
|---|---|
| Réplicas | 3 pods con HA Raft |
| Modo Vault | Server HA |
| TLS | CA y certificado generados mediante un pod UBI 9 |
| Route | Passthrough HTTPS; TLS directo al pod |
| Unseal | 5 claves con threshold de 3 |
| Persistencia | 10 Gi de datos y 5 Gi de auditoría por nodo |
| VaultConnection | CRD configurado |
| VaultAuth | CRD y método de autenticación Kubernetes configurados |
| Credenciales | Secret `vault-init-credentials` |
| Namespace VSO | `vault-secrets-operator-system` |

## REQUERIMIENTOS DE INFRAESTRUCTURA

| RECURSO | REQUEST | LIMIT |
|---|---:|---:|
| CPU por nodo, 3 nodos | 250m | 500m |
| Memoria por nodo, 3 nodos | 256 Mi | 512 Mi |
| Storage total | 45 Gi | - |
| Nodos mínimos | 3 workers | - |

## PRERREQUISITOS

- Namespace `vault` creado.
- IBM Entitlement Key aplicado en el namespace.
- Sesión activa mediante `oc login`.
- Vault Secrets Operator instalado para todos los namespaces.
- CRDs `VaultConnection`, `VaultAuth` y `VaultStaticSecret` disponibles.
- StorageClass `ocs-storagecluster-ceph-rbd` disponible.

## INSTALACIÓN Y ELIMINACIÓN

```bash
sh ./1_Script_Instalacion_Vault_[Operator]_PROD.sh --modalidad=install
sh ./1_Script_Instalacion_Vault_[Operator]_PROD.sh --modalidad=delete
```

> [!IMPORTANT]
> Este escenario proporciona alta disponibilidad, TLS end-to-end, almacenamiento persistente, audit log e integración con Kubernetes Auth.

---

# COMPARATIVA TÉCNICA

| CARACTERÍSTICA | HELM DESA | HELM PROD | OPERATOR DESA | OPERATOR PROD |
|---|---|---|---|---|
| Alta disponibilidad | No | 3 réplicas | No | 3 réplicas |
| TLS | HTTP | x509 con OpenSSL | Edge HTTPS | CA con UBI 9 |
| Datos persistentes | No | 45 Gi | 2 Gi | 45 Gi |
| Unseal automático | Sí, dev mode | No, 5 claves | No, 1 clave | No, 5 claves |
| Audit log PVC | No | 5 Gi x 3 | No | 5 Gi x 3 |
| Agent Injector | Sí | Sí | No aplica | No aplica |
| Vault Secrets Operator | No | No | Sí | Sí |
| Kubernetes Auth | No | No | No | Sí |
| PodDisruptionBudget | No | `maxUnavailable=1` | No | Administrado por Operator |
| CPU total solicitada | 100m | 800m | 100m | 750m |
| Memoria total solicitada | 128 Mi | 832 Mi | 128 Mi | 768 Mi |
| Herramientas | Helm CLI y `oc` | Helm CLI y `oc` | `oc` | `oc` |

# MIGRACIÓN ENTRE INSTANCIAS VAULT

La migración puede realizarse mediante dos modalidades.

## MODALIDAD `OC EXEC`: MISMO CLÚSTER

Se utiliza cuando las dos instancias Vault están desplegadas en el mismo clúster OpenShift.

- Requiere una sesión activa mediante `oc login`.
- Ejecuta comandos dentro del pod mediante `oc exec -i`.
- No requiere Vault CLI en el host.
- Vault se consume internamente mediante `127.0.0.1:8200`.
- Utiliza los parámetros `NS_ORIGEN`, `POD_ORIGEN`, `NS_DESTINO` y `POD_DESTINO`.

## MODALIDAD `VAULT-CLI`: CLÚSTERES DIFERENTES

Se utiliza cuando las instancias Vault están en clústeres, clouds o redes diferentes y sus endpoints HTTPS son accesibles desde el host.

- Requiere Vault CLI instalado en el host.
- No requiere `oc login` ni acceso directo a los pods.
- Es compatible con TechZone, AWS, Azure y entornos on-premises.
- Utiliza las direcciones `ADDR_ORIGEN` y `ADDR_DESTINO`.

```bash
# Configuración básica dentro del script de migración
MODO_CONEXION="vault-cli"
ADDR_ORIGEN="https://vault-ui-vault.apps.cluster-origen.techzone.ibm.com"
ADDR_DESTINO="https://vault-ui-vault.apps.cluster-destino.techzone.ibm.com"
TOKEN_ORIGEN="hvs.xxxx"
TOKEN_DESTINO="hvs.yyyy"
```

> [!CAUTION]
> No almacene tokens reales en el repositorio. Utilice variables de entorno, secretos protegidos o un mecanismo seguro de inyección de credenciales.

# RECOMENDACIONES

- Use los escenarios de desarrollo únicamente para pruebas funcionales.
- Seleccione tres o más workers para una topología HA de producción.
- Verifique la disponibilidad de `ocs-storagecluster-ceph-rbd` antes de desplegar PVCs.
- Proteja las claves de unseal y el root token fuera del clúster.
- Configure un mecanismo de auto-unseal para implementaciones productivas cuando la arquitectura y el proveedor de claves lo permitan.
- Valide certificados, rutas, políticas de red, audit log y recuperación ante desastres antes de liberar el servicio.

# DOCUMENTACIÓN

La guía visual completa está disponible en los archivos HTML y PDF asociados al proyecto.

---

**IBM Vault · Red Hat OpenShift**
