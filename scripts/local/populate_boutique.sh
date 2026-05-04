#!/bin/bash
# Populate boutique data via curl (avoids Python dep on progress/tqdm)
FRONTEND="${1:-http://localhost:4100}"
PRODUCT_CATALOG="${2:-http://localhost:4106}"
CURRENCY="${3:-http://localhost:4103}"
NUM_PRODUCTS="${4:-100}"

echo "Populating currencies..."
curl -s -X POST "$CURRENCY/init_currencies" \
    -H 'Content-Type: application/json' \
    -d '{"currencies":[{"currencyCode":"USD","rate":"1.0"},{"currencyCode":"EUR","rate":"0.85"},{"currencyCode":"GBP","rate":"0.75"},{"currencyCode":"JPY","rate":"110.0"},{"currencyCode":"CAD","rate":"1.25"}]}' > /dev/null
echo "  Currencies populated"

echo "Populating $NUM_PRODUCTS products..."
# Build product batch JSON
PRODUCTS="["
for i in $(seq 0 $((NUM_PRODUCTS - 1))); do
    [ "$i" -gt 0 ] && PRODUCTS="$PRODUCTS,"
    PRODUCTS="$PRODUCTS{\"id\":\"p$i\",\"name\":\"Product $i\",\"description\":\"Description for product $i\",\"picture\":\"pic$i\",\"priceUSD\":{\"currencyCode\":\"USD\",\"units\":$((10 + i % 90)),\"nanos\":0},\"categories\":[\"cat$((i % 5))\"]}"
done
PRODUCTS="$PRODUCTS]"

curl -s -X POST "$PRODUCT_CATALOG/add_products" \
    -H 'Content-Type: application/json' \
    -d "{\"products\":$PRODUCTS}" > /dev/null
echo "  $NUM_PRODUCTS products populated"
