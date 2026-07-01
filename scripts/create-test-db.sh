docker run -d --name evil-engine-postgres-test \
  -e POSTGRES_USER=evil_engine \
  -e POSTGRES_PASSWORD=evil_engine \
  -e POSTGRES_DB=evil_engine_dev \
  -p 5543:5432 \
  postgres:16-alpine

MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
