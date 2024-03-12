#!/usr/bin/env bash

trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT

ES_EXPORTER_DIR=/tmp/otelcol/file_storage/elasticsearchexporter
GENERATE_LOG_COUNT=${GENERATE_LOG_COUNT:-20000}
GENERATE_LOG_RATE=${GENERATE_LOG_RATE:-1000}

set -x

docker-compose down # cleanup
rm -rf $ES_EXPORTER_DIR
mkdir -p $ES_EXPORTER_DIR

docker-compose up -d
ocb --config=config.yaml --name="my-otelcol"
./build/my-otelcol --config otelcol.yaml &
COL_PID=$!

set +x
while true; do
    echo "waiting for ES to be ready..."
    curl -u admin:changeme \
        --header "Content-Type: application/json" \
        -X POST \
        -d '{"foo": "bar"}' \
        -s \
        http://localhost:9200/test/_doc && break
    sleep 1
done
set -x

(cd ./cmd/telemetrygen/ && go build -o main .)
./cmd/telemetrygen/main logs --otlp-endpoint=localhost:4317 --otlp-insecure --logs "$GENERATE_LOG_COUNT" --rate "$GENERATE_LOG_RATE" &
GEN_PID=$!

sleep 10
docker network disconnect otel-es-network otel-elasticsearch

wait $GEN_PID
kill -9 $COL_PID
sleep 5

docker network connect otel-es-network otel-elasticsearch

./build/my-otelcol --config otelcol.yaml &
COL_PID=$!
sleep 60 # persistent queue does not drain on shutdown
kill $COL_PID
wait $COL_PID

set +x
DOC_COUNT=$(curl -u "admin:changeme" \
    --header "Content-Type: application/json" \
    --request GET \
    -s \
    http://localhost:9200/foo/_count | jq '.count')
echo "generated logs: ${GENERATE_LOG_COUNT}; number of documents indexed: ${DOC_COUNT}"
