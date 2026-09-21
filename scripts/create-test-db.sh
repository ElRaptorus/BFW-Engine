docker run -d --name bfw-engine-postgres-test \
  -e POSTGRES_USER=bfw_engine \
  -e POSTGRES_PASSWORD=bfw_engine \
  -e POSTGRES_DB=bfw_engine_dev \
  -p 5543:5432 \
  postgres:16-alpine \
  postgres -c max_connections=100

MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
