#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# destroy-students.sh
#
# Elimina los usuarios IAM creados por create-students.sh. Limpia, en orden:
#   1. Stacks CloudFormation que cada estudiante haya dejado sin destruir.
#   2. Buckets S3 huerfanos con prefijo "workshop-agentes-${USERNAME}-".
#   3. Login profile, access keys, group memberships.
#   4. El usuario IAM.
#   5. (Opcional) el grupo del workshop si queda vacio.
#
# Pre-requisitos:
#   AWS CLI configurada como admin / root.
#
# Variables de entorno opcionales:
#   NUM_USERS, START_INDEX, USER_PREFIX, GROUP_NAME, REGION
#   PURGE_STACKS=true|false  (default true) — destruye stacks restantes.
#   PURGE_BUCKETS=true|false (default true) — vacia y borra buckets huerfanos.
#   DELETE_GROUP=true|false  (default false) — borra el grupo al final si esta vacio.
# ---------------------------------------------------------------------------

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
NUM_USERS="${NUM_USERS:-60}"
START_INDEX="${START_INDEX:-1}"
USER_PREFIX="${USER_PREFIX:-estudiante}"
GROUP_NAME="${GROUP_NAME:-WorkshopStudents}"
PURGE_STACKS="${PURGE_STACKS:-true}"
PURGE_BUCKETS="${PURGE_BUCKETS:-true}"
DELETE_GROUP="${DELETE_GROUP:-false}"

# Si DELETE_TEST_USER=true tambien borra ponente-test (default false: lo
# conservas por si quieres revalidar luego). Pon DELETE_TEST_USER=true al
# final del evento si quieres dejar la cuenta totalmente limpia.
DELETE_TEST_USER="${DELETE_TEST_USER:-false}"
TEST_USER_NAME="${TEST_USER_NAME:-ponente-test}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "==> Cuenta: ${ACCOUNT_ID} | Region: ${REGION}"
echo "==> Eliminando ${NUM_USERS} usuarios (${USER_PREFIX}$(printf '%02d' "${START_INDEX}").. ${USER_PREFIX}$(printf '%02d' $((START_INDEX + NUM_USERS - 1))))"
if [ "${DELETE_TEST_USER}" = "true" ]; then
  echo "    + usuario de prueba ${TEST_USER_NAME}"
fi
echo ""

END_INDEX=$((START_INDEX + NUM_USERS - 1))

# ---------------------------------------------------------------------------
# Funciones auxiliares para limpiar recursos de UN usuario.
# Las usamos tanto en el bucle de estudiantes como con el usuario de prueba.
# ---------------------------------------------------------------------------

purge_user_stack() {
  local username="$1"
  local stack_name="agente-soporte-${username}"

  local status
  status=$(aws cloudformation describe-stacks \
    --stack-name "${stack_name}" \
    --region "${REGION}" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "MISSING")

  if [ "${status}" = "MISSING" ]; then
    return 0
  fi

  echo "    [stack] ${stack_name} — estado ${status}, lanzando delete..."

  # Vaciar bucket frontend (si existe) antes de borrar el stack.
  local front_bucket
  front_bucket=$(aws cloudformation describe-stacks \
    --stack-name "${stack_name}" --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='FrontendBucket'].OutputValue" \
    --output text 2>/dev/null || true)
  if [ -n "${front_bucket}" ] && [ "${front_bucket}" != "None" ]; then
    aws s3 rm "s3://${front_bucket}/" --recursive --region "${REGION}" >/dev/null 2>&1 || true
  fi

  aws cloudformation delete-stack --stack-name "${stack_name}" --region "${REGION}" 2>/dev/null || true
}

wait_user_stack_deleted() {
  local username="$1"
  local stack_name="agente-soporte-${username}"
  aws cloudformation wait stack-delete-complete \
    --stack-name "${stack_name}" --region "${REGION}" 2>/dev/null || true
}

purge_user_bucket() {
  local username="$1"
  local bucket="workshop-agentes-${username}-${ACCOUNT_ID}"

  if aws s3api head-bucket --bucket "${bucket}" 2>/dev/null; then
    aws s3 rm "s3://${bucket}" --recursive --region "${REGION}" >/dev/null 2>&1 || true
    aws s3 rb "s3://${bucket}" --force --region "${REGION}" >/dev/null 2>&1 || true
    echo "    [bucket] eliminado ${bucket}"
  fi
}

delete_iam_user() {
  local username="$1"

  if ! aws iam get-user --user-name "${username}" >/dev/null 2>&1; then
    return 1   # skipped
  fi

  # Login profile.
  aws iam delete-login-profile --user-name "${username}" >/dev/null 2>&1 || true

  # Access keys.
  for akid in $(aws iam list-access-keys --user-name "${username}" \
                  --query "AccessKeyMetadata[].AccessKeyId" --output text 2>/dev/null); do
    [ -n "${akid}" ] && aws iam delete-access-key \
      --user-name "${username}" --access-key-id "${akid}" >/dev/null 2>&1 || true
  done

  # MFA devices.
  for mfa in $(aws iam list-mfa-devices --user-name "${username}" \
                  --query "MFADevices[].SerialNumber" --output text 2>/dev/null); do
    [ -n "${mfa}" ] && aws iam deactivate-mfa-device \
      --user-name "${username}" --serial-number "${mfa}" >/dev/null 2>&1 || true
  done

  # Group memberships.
  for grp in $(aws iam list-groups-for-user --user-name "${username}" \
                  --query "Groups[].GroupName" --output text 2>/dev/null); do
    [ -n "${grp}" ] && aws iam remove-user-from-group \
      --user-name "${username}" --group-name "${grp}" >/dev/null 2>&1 || true
  done

  # Inline policies.
  for pol in $(aws iam list-user-policies --user-name "${username}" \
                  --query "PolicyNames" --output text 2>/dev/null); do
    [ -n "${pol}" ] && aws iam delete-user-policy \
      --user-name "${username}" --policy-name "${pol}" >/dev/null 2>&1 || true
  done

  # Attached policies.
  for pol_arn in $(aws iam list-attached-user-policies --user-name "${username}" \
                      --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
    [ -n "${pol_arn}" ] && aws iam detach-user-policy \
      --user-name "${username}" --policy-arn "${pol_arn}" >/dev/null 2>&1 || true
  done

  # Permission boundary attached al user.
  aws iam delete-user-permissions-boundary --user-name "${username}" >/dev/null 2>&1 || true

  # Finalmente borra el usuario.
  if aws iam delete-user --user-name "${username}" 2>/dev/null; then
    return 0   # deleted
  else
    return 2   # error
  fi
}

# ---------------------------------------------------------------------------
# Fase 1: purgar stacks restantes por estudiante (si activado).
# ---------------------------------------------------------------------------
if [ "${PURGE_STACKS}" = "true" ]; then
  echo "==> Fase 1: destruyendo stacks restantes por estudiante..."
  for i in $(seq "${START_INDEX}" "${END_INDEX}"); do
    USERNAME="${USER_PREFIX}$(printf '%02d' "${i}")"
    purge_user_stack "${USERNAME}"
  done

  # Tambien el stack del ponente-test si DELETE_TEST_USER esta activo.
  if [ "${DELETE_TEST_USER}" = "true" ]; then
    purge_user_stack "${TEST_USER_NAME}"
  fi

  # Espera a que terminen los deletes.
  echo "    Esperando a que terminen los deletes (puede tardar unos minutos)..."
  for i in $(seq "${START_INDEX}" "${END_INDEX}"); do
    USERNAME="${USER_PREFIX}$(printf '%02d' "${i}")"
    wait_user_stack_deleted "${USERNAME}"
  done
  if [ "${DELETE_TEST_USER}" = "true" ]; then
    wait_user_stack_deleted "${TEST_USER_NAME}"
  fi
  echo "    Stacks procesados."
fi

# ---------------------------------------------------------------------------
# Fase 2: borrar buckets de assets huerfanos.
# ---------------------------------------------------------------------------
if [ "${PURGE_BUCKETS}" = "true" ]; then
  echo "==> Fase 2: borrando buckets de assets por estudiante..."
  for i in $(seq "${START_INDEX}" "${END_INDEX}"); do
    USERNAME="${USER_PREFIX}$(printf '%02d' "${i}")"
    purge_user_bucket "${USERNAME}"
  done

  if [ "${DELETE_TEST_USER}" = "true" ]; then
    purge_user_bucket "${TEST_USER_NAME}"
  fi
fi

# ---------------------------------------------------------------------------
# Fase 3: eliminar usuarios IAM (login profile, keys, group memberships, user).
# ---------------------------------------------------------------------------
echo "==> Fase 3: eliminando usuarios IAM..."
DELETED=0
SKIPPED=0

for i in $(seq "${START_INDEX}" "${END_INDEX}"); do
  USERNAME="${USER_PREFIX}$(printf '%02d' "${i}")"

  set +e
  delete_iam_user "${USERNAME}"
  RC=$?
  set -e

  case "${RC}" in
    0) echo "    [delete] ${USERNAME}"; DELETED=$((DELETED + 1)) ;;
    1) SKIPPED=$((SKIPPED + 1)) ;;
    *) echo "    [error]  ${USERNAME} — no se pudo borrar (revisa dependencias)" ;;
  esac
done

# Usuario de prueba del ponente.
if [ "${DELETE_TEST_USER}" = "true" ]; then
  set +e
  delete_iam_user "${TEST_USER_NAME}"
  RC=$?
  set -e

  case "${RC}" in
    0) echo "    [delete] ${TEST_USER_NAME}"; DELETED=$((DELETED + 1)) ;;
    1) echo "    [skip]   ${TEST_USER_NAME} (no existia)" ;;
    *) echo "    [error]  ${TEST_USER_NAME} — revisa dependencias" ;;
  esac
else
  if aws iam get-user --user-name "${TEST_USER_NAME}" >/dev/null 2>&1; then
    echo "    [keep]   ${TEST_USER_NAME} (DELETE_TEST_USER=false; pasa DELETE_TEST_USER=true para borrarlo)"
  fi
fi

# ---------------------------------------------------------------------------
# Fase 4: opcional, borrar el grupo si quedo vacio.
# ---------------------------------------------------------------------------
if [ "${DELETE_GROUP}" = "true" ]; then
  echo "==> Fase 4: borrando grupo ${GROUP_NAME}..."
  if aws iam get-group --group-name "${GROUP_NAME}" >/dev/null 2>&1; then
    # Detach policies del grupo.
    for POL_ARN in $(aws iam list-attached-group-policies --group-name "${GROUP_NAME}" \
                        --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
      [ -n "${POL_ARN}" ] && aws iam detach-group-policy \
        --group-name "${GROUP_NAME}" --policy-arn "${POL_ARN}" >/dev/null 2>&1 || true
    done
    aws iam delete-group --group-name "${GROUP_NAME}" >/dev/null 2>&1 || true
    echo "    Grupo eliminado."
  fi
fi

echo ""
echo "✅ Limpieza completa."
echo "    Borrados: ${DELETED}"
echo "    No existian: ${SKIPPED}"
echo ""
echo "ℹ️  La policy de boundary (WorkshopBoundaryPolicy) NO se borra automaticamente."
echo "   Si la quieres eliminar:"
echo "     aws cloudformation delete-stack --stack-name workshop-boundary --region ${REGION}"
