#!/bin/bash
# Populate hotel data via curl (avoids Python dependency on tqdm)
FRONTEND="${1:-http://localhost:4000}"
USER_SVC="${2:-http://localhost:4005}"
NUM_HOTELS="${3:-100}"
NUM_USERS="${4:-20}"

echo "Populating $NUM_HOTELS hotels..."
for i in $(seq 0 $((NUM_HOTELS - 1))); do
    city="city$((i % 10))"
    curl -s -X POST "$FRONTEND/store_hotel" \
        -H 'Content-Type: application/json' \
        -d "{\"hotel_id\":\"$i\",\"name\":\"Hotel $i\",\"phone\":\"555-$i\",\"location\":\"$city\",\"rate\":100,\"capacity\":11,\"info\":\"info$i\"}" > /dev/null
done
echo "  $NUM_HOTELS hotels populated"

echo "Populating $NUM_USERS users..."
for i in $(seq 0 $((NUM_USERS - 1))); do
    curl -s -X POST "$USER_SVC/register_user" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"username$i\",\"password\":\"password$i\"}" > /dev/null
done
echo "  $NUM_USERS users populated"
