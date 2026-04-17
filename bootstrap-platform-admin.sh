# Fetch the Keycloak UUID for the admin user
KC_ADMIN_UUID=$(curl -s -X GET "${KEYCLOAK_ADMIN_URL}/admin/realms/credebl/users?email=admin@cdpi-poc.local" \
  -H "Authorization: Bearer $KC_TOKEN" | jq -r '.[0].id')

if [ "$KC_ADMIN_UUID" != "null" ]; then
  echo "Syncing Keycloak ID $KC_ADMIN_UUID to Postgres..."
  docker exec -t credebl-postgres psql -U credebl -d credebl -c \
    "UPDATE \"user\" SET \"keycloak_id\" = '$KC_ADMIN_UUID' WHERE \"email\" = 'admin@cdpi-poc.local';"
else
  echo "Error: Could not find admin user in Keycloak"
  exit 1
fi
