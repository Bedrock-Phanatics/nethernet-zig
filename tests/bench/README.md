## light test
zig build stress -Doptimize=ReleaseFast -- \
  --connections 1000 \
  --duration-ms 60000 \
  --rate 20 \
  --burst 4 \
  --max-in-flight 64 \
  --payload-size 8192 \
  --profile bedrock \
  --reliability mixed

## heavier test
zig build stress -Doptimize=ReleaseFast -- \
  --connections 1000 \
  --duration-ms 60000 \
  --rate 60 \
  --burst 8 \
  --max-in-flight 128 \
  --payload-size 8192 \
  --profile bedrock \
  --reliability mixed
