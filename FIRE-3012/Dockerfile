FROM node:22-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev procps && rm -rf /var/lib/apt/lists/*
RUN npm install -g @anthropic-ai/claude-code @openai/codex >/dev/null 2>&1
RUN useradd -m -s /bin/bash tester
COPY stub.c /tmp/stub.c
RUN gcc -O2 -o /tmp/rogue-hook /tmp/stub.c
USER tester
RUN mkdir -p /home/tester/.rogue-spike-3012/bin /home/tester/work && cp /tmp/rogue-hook /home/tester/.rogue-spike-3012/bin/rogue-hook
WORKDIR /home/tester/work
